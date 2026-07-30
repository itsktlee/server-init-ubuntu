#!/usr/bin/env bash

set -Eeuo pipefail

# ========== 高级选项，通常不需要修改 ==========
# 运行时会交互询问要创建并允许 SSH 登录的管理员用户名。
ADMIN_USER="${ADMIN_USER:-}"

# SSH 端口。默认在运行时询问，也可通过 SSH_PORT 环境变量指定。
SSH_PORT="${SSH_PORT:-}"

# 时区。auto 会根据服务器公网出口 IP 推断；也可指定 America/New_York 等值。
TIMEZONE="${TIMEZONE:-auto}"

# 额外开放的 TCP 端口，以空格分隔。默认不开放业务端口。
# 示例：PUBLIC_TCP_PORTS="80 443"
PUBLIC_TCP_PORTS="${PUBLIC_TCP_PORTS:-}"

# 是否启用主机 UFW 防火墙。推荐保持 yes。
ENABLE_UFW="${ENABLE_UFW:-yes}"

# 是否在系统没有 swap 时创建 swap 文件。
CREATE_SWAP="${CREATE_SWAP:-yes}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-4096}"

# systemd journal 最大磁盘占用。
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-1G}"

# 是否在初始化时升级所有已安装软件包。
UPGRADE_PACKAGES="${UPGRADE_PACKAGES:-yes}"

# 是否安装并优化 Docker。
INSTALL_DOCKER="${INSTALL_DOCKER:-yes}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/var/lib/docker}"
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-100m}"
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"

# 是否每天 03:30 清理长期未使用的镜像、构建缓存和已停止容器。
# 不会清理 volume；240h 表示只处理 10 天前的对象。
ENABLE_DOCKER_PRUNE="${ENABLE_DOCKER_PRUNE:-no}"
DOCKER_PRUNE_UNTIL="${DOCKER_PRUNE_UNTIL:-240h}"
# ==================================================

readonly SSH_DROP_IN="/etc/ssh/sshd_config.d/00-server-init.conf"
readonly FAIL2BAN_DROP_IN="/etc/fail2ban/jail.d/server-init.local"
readonly JOURNAL_DROP_IN="/etc/systemd/journald.conf.d/99-size.conf"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-server-init.conf"
readonly DOCKER_CONFIG="/etc/docker/daemon.json"

log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

backup_file() {
  local file="$1"
  local backup

  [[ -f "${file}" ]] || return 0
  backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "${file}" "${backup}"
  log "已备份 ${file} 到 ${backup}"
}

validate_yes_no() {
  local name="$1"
  local value="$2"
  [[ "${value}" == "yes" || "${value}" == "no" ]] ||
    die "${name} 只能设置为 yes 或 no。"
}

is_valid_port() {
  local port="$1"
  [[ "${port}" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535))
}

prompt_ssh_port() {
  local port_input

  if [[ -n "${SSH_PORT}" ]]; then
    return 0
  fi

  while true; do
    read -r -p "请输入 SSH 端口（1-65535，请先在云防火墙放行）: " port_input
    if is_valid_port "${port_input}"; then
      SSH_PORT="${port_input}"
      return 0
    fi
    warn "端口必须是 1 到 65535 之间的数字，请重新输入。"
  done
}

is_valid_timezone() {
  local timezone="$1"

  [[ "${timezone}" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] &&
    [[ -e "/usr/share/zoneinfo/${timezone}" ]]
}

resolve_timezone() {
  if [[ "${TIMEZONE}" != "auto" ]]; then
    is_valid_timezone "${TIMEZONE}" ||
      die "无效时区：${TIMEZONE}。请使用 America/New_York 这类 IANA 时区名称。"
    return 0
  fi

  local detected_timezone
  local lookup_url
  local -a lookup_urls=(
    "https://ipinfo.io/timezone"
    "https://ipapi.co/timezone"
  )

  log "根据服务器公网出口 IP 自动识别时区"
  for lookup_url in "${lookup_urls[@]}"; do
    detected_timezone="$(
      curl --proto '=https' --tlsv1.2 -fsS --max-time 8 "${lookup_url}" |
        tr -d '\r\n' || true
    )"
    if is_valid_timezone "${detected_timezone}"; then
      TIMEZONE="${detected_timezone}"
      log "识别到时区：${TIMEZONE}"
      return 0
    fi
  done

  TIMEZONE="UTC"
  warn "无法根据公网 IP 识别时区，已安全回退到 UTC。"
}

validate_environment() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 sudo 执行此脚本。"
  [[ -r /etc/os-release ]] || die "无法识别操作系统。"

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "此脚本仅支持 Ubuntu。"

  [[ -t 0 ]] || die "创建用户和设置密码需要交互式终端，请直接运行：sudo ./init_server.sh"
  command -v adduser >/dev/null 2>&1 || die "系统缺少 adduser 命令。"
  command -v passwd >/dev/null 2>&1 || die "系统缺少 passwd 命令。"
  command -v sudo >/dev/null 2>&1 || die "系统未安装 sudo。"
  getent group sudo >/dev/null 2>&1 || die "系统不存在 sudo 用户组。"
}

prepare_admin_user() {
  local reuse_user
  local reset_password="yes"

  if [[ -z "${ADMIN_USER}" ]]; then
    read -r -p "请输入要创建并允许 SSH 登录的用户名: " ADMIN_USER
  fi

  [[ "${ADMIN_USER}" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] ||
    die "用户名必须以小写字母开头，只能包含小写字母、数字、下划线和连字符。"
  [[ "${ADMIN_USER}" != "root" ]] || die "不能使用 root 作为管理员用户名。"

  if id "${ADMIN_USER}" >/dev/null 2>&1; then
    warn "用户 ${ADMIN_USER} 已存在。"
    read -r -p "继续使用该用户吗？[y/N]: " reuse_user
    [[ "${reuse_user}" == "y" || "${reuse_user}" == "Y" ]] ||
      die "已取消。请重新运行并输入其他用户名。"
    read -r -p "需要重新设置该用户的密码吗？[y/N]: " reset_password
  else
    log "创建用户 ${ADMIN_USER}"
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
  fi

  if [[ "${reset_password}" == "yes" ||
    "${reset_password}" == "y" || "${reset_password}" == "Y" ]]; then
    printf '\n请为用户 %s 设置登录密码：\n' "${ADMIN_USER}"
    passwd "${ADMIN_USER}"
  fi

  log "授予 ${ADMIN_USER} sudo 权限"
  usermod -aG sudo "${ADMIN_USER}"
  warn "SSH 配置生效后，请保持当前会话在线，直到 ${ADMIN_USER} 的新连接测试成功。"
}

validate_settings() {

  id "${ADMIN_USER}" >/dev/null 2>&1 || die "用户 ${ADMIN_USER} 不存在。"

  local user_shell
  user_shell="$(getent passwd "${ADMIN_USER}" | cut -d: -f7)"
  [[ "${user_shell}" != */nologin && "${user_shell}" != */false ]] ||
    die "用户 ${ADMIN_USER} 没有可登录的 shell。"

  local password_status
  password_status="$(passwd -S "${ADMIN_USER}" | awk '{print $2}')"
  [[ "${password_status}" == "P" ]] ||
    die "用户 ${ADMIN_USER} 尚未设置可用密码，请先执行：sudo passwd ${ADMIN_USER}"

  sudo -l -U "${ADMIN_USER}" >/dev/null 2>&1 ||
    die "用户 ${ADMIN_USER} 的 sudo 权限配置失败。"

  is_valid_port "${SSH_PORT}" ||
    die "SSH_PORT 必须是 1 到 65535 之间的数字。"

  [[ "${SWAP_SIZE_MB}" =~ ^[0-9]+$ ]] && ((SWAP_SIZE_MB >= 512)) ||
    die "SWAP_SIZE_MB 必须是大于等于 512 的整数。"

  validate_yes_no "ENABLE_UFW" "${ENABLE_UFW}"
  validate_yes_no "CREATE_SWAP" "${CREATE_SWAP}"
  validate_yes_no "UPGRADE_PACKAGES" "${UPGRADE_PACKAGES}"
  validate_yes_no "INSTALL_DOCKER" "${INSTALL_DOCKER}"
  validate_yes_no "ENABLE_DOCKER_PRUNE" "${ENABLE_DOCKER_PRUNE}"

  [[ "${DOCKER_DATA_ROOT}" == /* ]] ||
    die "DOCKER_DATA_ROOT 必须是绝对路径。"
  [[ "${DOCKER_LOG_MAX_FILE}" =~ ^[0-9]+$ ]] &&
    ((DOCKER_LOG_MAX_FILE >= 1)) ||
    die "DOCKER_LOG_MAX_FILE 必须是大于等于 1 的整数。"
  [[ "${DOCKER_PRUNE_UNTIL}" =~ ^[0-9]+(s|m|h)$ ]] ||
    die "DOCKER_PRUNE_UNTIL 格式无效，请使用 30m、24h 或 240h 这类格式。"

  local -a public_ports=()
  local port
  read -r -a public_ports <<<"${PUBLIC_TCP_PORTS}"
  for port in "${public_ports[@]}"; do
    [[ "${port}" =~ ^[0-9]+$ ]] &&
      ((port >= 1 && port <= 65535)) ||
      die "无效的业务端口：${port}"
  done
}

configure_passwordless_sudo() {
  local sudoers_file="/etc/sudoers.d/90-${ADMIN_USER}-nopasswd"
  local sudoers_temp
  sudoers_temp="$(mktemp)"

  log "配置 ${ADMIN_USER} 使用 sudo 时无需输入密码"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${ADMIN_USER}" >"${sudoers_temp}"
  chmod 0440 "${sudoers_temp}"

  if ! visudo -cf "${sudoers_temp}" >/dev/null; then
    rm -f "${sudoers_temp}"
    die "免密码 sudo 配置校验失败，未修改系统 sudoers。"
  fi

  install -o root -g root -m 0440 "${sudoers_temp}" "${sudoers_file}"
  rm -f "${sudoers_temp}"
  visudo -cf /etc/sudoers >/dev/null ||
    die "系统 sudoers 完整配置校验失败。"
}

install_base_system() {
  log "更新软件包索引"
  apt-get update

  if [[ "${UPGRADE_PACKAGES}" == "yes" ]]; then
    log "升级已安装的软件包"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi

  log "安装常用工具和安全组件"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server \
    ca-certificates curl wget \
    vim git rsync tar unzip \
    lsof dnsutils jq bash-completion iproute2 \
    ufw chrony fail2ban

  resolve_timezone
  log "设置时区为 ${TIMEZONE}"
  timedatectl set-timezone "${TIMEZONE}"
  systemctl enable --now chrony
}

restore_ssh_config() {
  local rollback_dir="$1"
  local had_drop_in="$2"

  cp -a "${rollback_dir}/sshd_config" /etc/ssh/sshd_config
  if [[ "${had_drop_in}" == "yes" ]]; then
    cp -a "${rollback_dir}/ssh_drop_in" "${SSH_DROP_IN}"
  else
    rm -f "${SSH_DROP_IN}"
  fi
}

reload_ssh() {
  # Ubuntu 24.04 可能通过 ssh.socket 监听端口，daemon-reload 会重新运行
  # systemd 的 SSH socket generator，使 Port 配置真正生效。
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket
  fi
  systemctl reload-or-restart ssh.service
}

configure_ssh() {
  log "配置 SSH：允许普通用户使用密码或密钥登录，禁止 root 登录"
  local rollback_dir
  local had_drop_in="no"
  local effective_config
  local config_error=""
  rollback_dir="$(mktemp -d)"

  # sshd -t 在部分精简系统或尚未启动过 SSH 服务的机器上要求此目录存在。
  install -d -o root -g root -m 0755 /run/sshd

  cp -a /etc/ssh/sshd_config "${rollback_dir}/sshd_config"
  if [[ -f "${SSH_DROP_IN}" ]]; then
    cp -a "${SSH_DROP_IN}" "${rollback_dir}/ssh_drop_in"
    had_drop_in="yes"
  fi

  install -d -m 0755 /etc/ssh/sshd_config.d
  backup_file /etc/ssh/sshd_config
  backup_file "${SSH_DROP_IN}"

  # Ubuntu 默认包含此目录；兼容缺少 Include 指令的自定义配置。
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
    /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi

  cat >"${SSH_DROP_IN}" <<EOF
# Managed by init_server.sh
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
UsePAM yes
MaxAuthTries 5
LoginGraceTime 60
X11Forwarding no
GSSAPIAuthentication no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  chown root:root "${SSH_DROP_IN}"
  chmod 0600 "${SSH_DROP_IN}"

  if ! sshd -t; then
    config_error="SSH 配置语法校验失败。"
  else
    effective_config="$(sshd -T)"
    grep -qx 'permitrootlogin no' <<<"${effective_config}" ||
      config_error="SSH 最终配置未成功禁止 root 登录。"
    grep -qx 'passwordauthentication yes' <<<"${effective_config}" ||
      config_error="SSH 最终配置未成功开启密码认证。"
    grep -qx 'pubkeyauthentication yes' <<<"${effective_config}" ||
      config_error="SSH 最终配置未成功开启公钥认证。"
  fi

  if [[ -n "${config_error}" ]]; then
    warn "SSH 配置校验失败，正在恢复原配置"
    restore_ssh_config "${rollback_dir}" "${had_drop_in}"
    rm -rf "${rollback_dir}"
    die "${config_error} 已恢复原配置，SSH 服务未重载。"
  fi

  if ! reload_ssh ||
    ! ss -lntH "sport = :${SSH_PORT}" | grep -q .; then
    warn "SSH 未能在 ${SSH_PORT} 端口正常监听，正在恢复原配置"
    restore_ssh_config "${rollback_dir}" "${had_drop_in}"
    reload_ssh || true
    rm -rf "${rollback_dir}"
    die "SSH 端口切换失败，已恢复原配置。"
  fi

  rm -rf "${rollback_dir}"
}

configure_fail2ban() {
  log "配置 fail2ban，限制 SSH 密码暴力尝试"
  install -d -m 0755 /etc/fail2ban/jail.d

  cat >"${FAIL2BAN_DROP_IN}" <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
EOF

  fail2ban-client -t
  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

configure_firewall() {
  if [[ "${ENABLE_UFW}" != "yes" ]]; then
    warn "已按配置跳过 UFW；请确保云防火墙或上级网络防火墙规则正确。"
    return 0
  fi

  log "配置 UFW 防火墙"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment "SSH"

  local -a public_ports=()
  local port
  read -r -a public_ports <<<"${PUBLIC_TCP_PORTS}"
  for port in "${public_ports[@]}"; do
    ufw allow "${port}/tcp"
  done

  ufw --force enable
}

configure_logs() {
  log "限制 systemd journal 的磁盘占用"
  install -d -m 0755 /etc/systemd/journald.conf.d

  cat >"${JOURNAL_DROP_IN}" <<EOF
[Journal]
SystemMaxUse=${JOURNAL_MAX_USE}
SystemMaxFileSize=200M
SystemKeepFree=500M
Compress=yes
EOF

  systemctl restart systemd-journald
}

configure_kernel() {
  log "应用保守的通用服务器内核参数"
  cat >"${SYSCTL_CONFIG}" <<'EOF'
# Managed by init_server.sh
fs.file-max = 1048576
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
vm.swappiness = 10
EOF

  if [[ "${INSTALL_DOCKER}" == "yes" ]]; then
    cat >>"${SYSCTL_CONFIG}" <<'EOF'
net.ipv4.ip_forward = 1
vm.max_map_count = 262144
EOF
  fi

  sysctl --system
}

configure_swap() {
  [[ "${CREATE_SWAP}" == "yes" ]] || return 0

  if swapon --show --noheadings | grep -q .; then
    log "系统已有启用的 swap，跳过创建"
    return 0
  fi

  if [[ -e /swapfile ]]; then
    if [[ "$(blkid -p -s TYPE -o value /swapfile 2>/dev/null || true)" == "swap" ]]; then
      log "启用已有的 /swapfile"
      chmod 0600 /swapfile
      swapon /swapfile
    else
      warn "/swapfile 已存在但不是 swap，出于安全考虑跳过创建"
      return 0
    fi
  else
    log "创建 ${SWAP_SIZE_MB}MB swap 文件"
    fallocate -l "${SWAP_SIZE_MB}M" /swapfile ||
      dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}" status=progress
    chmod 0600 /swapfile
    mkswap /swapfile
    swapon /swapfile
  fi

  if ! grep -Eq '^[^#]*[[:space:]]/swapfile[[:space:]]' /etc/fstab; then
    printf '/swapfile swap swap defaults 0 0\n' >>/etc/fstab
  fi
}

install_docker() {
  [[ "${INSTALL_DOCKER}" == "yes" ]] || return 0

  log "移除可能与 Docker CE 冲突的旧容器组件"
  DEBIAN_FRONTEND=noninteractive apt-get remove -y \
    docker.io \
    docker-doc \
    docker-compose \
    docker-compose-v2 \
    podman-docker \
    containerd \
    runc || true

  log "添加 Docker 官方软件源"
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
    gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local version_codename
  local architecture
  version_codename="$(
    # shellcheck disable=SC1091
    source /etc/os-release
    printf '%s' "${VERSION_CODENAME}"
  )"
  architecture="$(dpkg --print-architecture)"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${architecture} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${version_codename} stable
EOF

  apt-get update

  log "安装 Docker Engine、Buildx 和 Compose"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker
}

configure_docker() {
  [[ "${INSTALL_DOCKER}" == "yes" ]] || return 0

  log "配置 Docker 日志轮转、live-restore 和数据目录"
  install -d -m 0755 /etc/docker
  backup_file "${DOCKER_CONFIG}"

  local desired_config
  local merged_config
  desired_config="$(mktemp)"
  merged_config="$(mktemp)"

  jq -n \
    --arg data_root "${DOCKER_DATA_ROOT}" \
    --arg max_size "${DOCKER_LOG_MAX_SIZE}" \
    --arg max_file "${DOCKER_LOG_MAX_FILE}" \
    '{
      "data-root": $data_root,
      "log-driver": "json-file",
      "log-opts": {
        "max-size": $max_size,
        "max-file": $max_file
      },
      "live-restore": true,
      "iptables": true,
      "ip-forward": true,
      "storage-driver": "overlay2",
      "features": {
        "buildkit": true
      }
    }' >"${desired_config}"

  if [[ -s "${DOCKER_CONFIG}" ]]; then
    jq empty "${DOCKER_CONFIG}" ||
      die "${DOCKER_CONFIG} 不是有效 JSON；已保留原文件，请手动处理。"
    jq -s '.[0] * .[1]' "${DOCKER_CONFIG}" "${desired_config}" >"${merged_config}"
  else
    cp "${desired_config}" "${merged_config}"
  fi

  dockerd --validate --config-file="${merged_config}"
  install -m 0644 "${merged_config}" "${DOCKER_CONFIG}"
  rm -f "${desired_config}" "${merged_config}"

  systemctl restart docker
  docker version

  configure_docker_prune
}

configure_docker_prune() {
  if [[ "${ENABLE_DOCKER_PRUNE}" != "yes" ]]; then
    if systemctl list-unit-files docker-prune.timer --no-legend 2>/dev/null |
      grep -q '^docker-prune.timer'; then
      systemctl disable --now docker-prune.timer
      warn "已禁用现有 Docker 定时清理任务。"
    else
      warn "已跳过 Docker 定时清理。"
    fi
    return 0
  fi

  log "配置每天一次的 Docker 安全清理任务"
  cat >/usr/local/sbin/docker-prune-safe.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

# 不使用 --volumes，避免清理 Docker 数据卷。
/usr/bin/docker system prune -af --filter "until=${DOCKER_PRUNE_UNTIL}"
EOF
  chmod 0750 /usr/local/sbin/docker-prune-safe.sh

  cat >/etc/systemd/system/docker-prune.service <<'EOF'
[Unit]
Description=Prune old unused Docker objects
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/docker-prune-safe.sh
EOF

  cat >/etc/systemd/system/docker-prune.timer <<'EOF'
[Unit]
Description=Run Docker prune daily

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now docker-prune.timer
}

show_summary() {
  log "初始化完成"
  printf '\nSSH 最终配置：\n'
  sshd -T | grep -E \
    '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|maxauthtries) '

  if [[ "${ENABLE_UFW}" == "yes" ]]; then
    printf '\n防火墙状态：\n'
    ufw status verbose
  fi

  printf '\n时间同步：'
  systemctl is-active chrony

  printf 'fail2ban：'
  systemctl is-active fail2ban

  if [[ "${INSTALL_DOCKER}" == "yes" ]]; then
    printf 'Docker：'
    systemctl is-active docker
    docker --version
    docker compose version
    warn "Docker 发布到 0.0.0.0 的端口可能绕过普通 UFW 入站规则，请同时维护云防火墙。"
    warn "默认未将 ${ADMIN_USER} 加入 docker 组，请使用 sudo docker；docker 组等价于 root 权限。"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    warn "系统更新后需要重启。请先另开终端确认 ${ADMIN_USER} 的 SSH 密码登录正常，再执行 reboot。"
  else
    warn "请先另开终端确认 ${ADMIN_USER} 的 SSH 密码登录正常，再关闭当前会话。"
  fi
}

main() {
  validate_environment
  prepare_admin_user
  prompt_ssh_port
  validate_settings
  configure_passwordless_sudo
  install_base_system
  configure_ssh
  configure_fail2ban
  configure_firewall
  configure_logs
  configure_kernel
  configure_swap
  install_docker
  configure_docker
  show_summary
}

main "$@"
