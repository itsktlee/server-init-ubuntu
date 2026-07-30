# Ubuntu 服务器初始化

面向 Ubuntu 的单文件首次初始化脚本。适用于云服务器和本地服务器。

脚本会完成：

- 更新系统并安装常用运维工具
- 根据服务器公网 IP 自动识别时区，并配置 chrony 时间同步
- 交互创建一个自定义管理员用户并设置密码
- 配置该用户使用 sudo 时无需再次输入密码
- 允许密码或 SSH 密钥认证，禁止 root SSH 登录
- 配置 fail2ban 和 UFW
- 限制 systemd journal 磁盘占用
- 应用保守的通用服务器内核参数
- 在系统没有 swap 时创建 swap 文件
- 从 Docker 官方软件源安装 Engine、Buildx 和 Compose
- 配置 Docker 日志轮转、live-restore 和 BuildKit

## 使用

使用云厂商提供的临时账号（如 `admin`），或本地安装时创建的临时账号（如
`ubuntu`）登录服务器，进入脚本目录后执行：

```bash
sudo ./init_server.sh
```

脚本会依次要求：

- 输入你自己的新用户名
- 输入两次新用户密码，输入时终端不会显示字符
- 如果输入的用户已经存在，确认是否复用以及是否重设密码
- 输入要使用的 SSH 端口，并检查端口范围是否有效

脚本随后会创建用户、加入 `sudo` 组，并按你输入的端口配置 SSH：

- 可以使用用户名和密码登录
- 也保留 SSH 密钥登录能力
- 禁止 root 通过 SSH 登录
- 新用户执行 `sudo` 时不再要求输入密码

原有的 `admin`、`ubuntu` 等普通用户不会被删除或禁止，仍可作为备用登录
账号。SSH 密码暴力尝试由 fail2ban 限制。

免密码 sudo 使用 `NOPASSWD: ALL`，便利性较高，但该用户一旦被入侵，对方也
可以直接获得 root 权限。因此必须使用强密码，并保留 fail2ban 和防火墙。

脚本完成后不要关闭当前 SSH 会话。先另开一个终端，使用新用户名和密码
测试登录；确认新连接及 `sudo` 正常后，再退出旧会话或重启服务器。

默认通过 HTTPS IP 地理定位服务推断服务器时区。识别失败时使用 `UTC`。
云服务器出口 IP 定位不准确时，可以在运行脚本时手动指定：

```bash
sudo TIMEZONE=America/New_York ./init_server.sh
```

输入的 SSH 端口必须同时在云厂商防火墙中放行。新连接使用：

```bash
ssh -p 你输入的端口 新用户名@服务器IP
```

如需非交互指定用户名，也可以执行下面的命令，但密码仍会交互输入：

```bash
sudo ADMIN_USER=myuser ./init_server.sh
```

SSH 端口也可以通过环境变量提前指定：

```bash
sudo SSH_PORT=2201 ./init_server.sh
```

## 防火墙

推荐同时开启云厂商防火墙和 UFW。云防火墙负责公网入口，UFW 负责主机及
内网入口；最终允许的是两者规则的交集，所以任意一层未放行都会导致端口
不通。

默认 UFW 只放行 SSH。部署网站时可以执行：

```bash
sudo PUBLIC_TCP_PORTS="80 443" ./init_server.sh
```

如果明确只使用上级防火墙，可关闭 UFW 配置步骤：

```bash
sudo ENABLE_UFW=no ./init_server.sh
```

Docker 发布到 `0.0.0.0` 的端口可能绕过普通 UFW 入站规则。云服务器应继续
使用云防火墙限制这些端口；本地服务器应只发布必要端口，内部服务可绑定到
`127.0.0.1`。

默认不把管理员加入 `docker` 组，因为该组实际上拥有 root 级权限。日常使用：

```bash
sudo docker ps
sudo docker compose version
```

Docker 自动清理默认关闭。开启后，初始化脚本会安装一个 systemd 定时器，
此后每天 03:30 自动清理 10 天前未使用的镜像、构建缓存和已停止容器，
不需要重复运行初始化脚本，也不会清理 volume。启用方式：

```bash
sudo ENABLE_DOCKER_PRUNE=yes ./init_server.sh
```
