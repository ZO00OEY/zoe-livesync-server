# Zoe LiveSync Server

完全独立的一键安装项目，为 Obsidian Self-hosted LiveSync 部署 CouchDB、独立 Caddy 入口和 Let's Encrypt 公网 IP 短期证书。

本项目不依赖、读取或修改任何旧项目，也不改写服务器上已有的 Caddy、Nginx 或代理节点配置。

## 当前功能

- 启动后检查 Linux 发行版、版本、架构、Docker 和 Compose。
- Debian 12/13、Ubuntu 22.04/24.04/26.04 走 Docker 官方源直接安装。
- Debian 11、Ubuntu 18.04 等旧系统及其他 Linux 走发行版软件包兼容安装。
- 已有可用 Docker + Compose 时，不限制 Linux 发行版。
- 从多个直连公网查询和云厂商元数据收集公网 IPv4 候选。
- 不显示或接受局域网、CGNAT、回环、文档示例及其他保留地址。
- 候选 IP 不一致时明确警告，由用户确认，不静默猜测。
- 使用 `acme.sh` 和 Let's Encrypt `shortlived` profile 签发公网 IP 证书。
- 默认从 `20000-29999` 随机选择一个未占用的独立 HTTPS 端口，并在安装结束时醒目显示。
- 不停止、不改写、不接管服务器上已有的代理节点。
- 每 12 小时检查证书续期；证书更新后自动重载本项目自己的 Caddy。
- CouchDB 仅绑定 `127.0.0.1:5984`，不会把数据库原始端口暴露到公网。
- 自动配置 Self-hosted LiveSync 所需的 CORS、认证和大小限制。
- 生成可直接填写到 Self-hosted LiveSync 的连接信息。

## 一键安装

```bash
git clone https://github.com/ZO00OEY/zoe-livesync-server.git
cd zoe-livesync-server
sudo bash install.sh
```

脚本会确认公网 IPv4，并随机选择不冲突的 HTTPS 端口，例如：

```text
https://公网IP:随机端口
```

如果需要明确指定：

```bash
sudo PUBLIC_IP=你的公网IP HTTPS_PORT=8443 bash install.sh
```

非交互安装必须明确指定公网 IP：

```bash
sudo PUBLIC_IP=你的公网IP HTTPS_PORT=8443 NON_INTERACTIVE=1 bash install.sh --non-interactive
```

## 只检查公网 IP

```bash
bash install.sh --detect-ip
```

该模式不安装服务，也不会显示局域网地址。

## Self-hosted LiveSync 连接信息

```text
Remote type: CouchDB
API 类型: CouchDB
API URL: https://公网IP:随机端口
HTTPS 端口: 随机端口
Username: 自动生成或指定的用户名
Password: 自动生成或指定的密码
Database: obsidiannotes
```

随后还会生成：

- Vault 端到端加密口令。
- Setup URI 保护口令。
- `obsidian://setuplivesync?...` 快速导入地址。

完整信息保存在：

```text
/opt/zoe-livesync-server/connection.txt
```

该文件和 `.env` 权限均为 `600`，不要提交或公开发送。

## 管理

```bash
sudo /opt/zoe-livesync-server/manage.sh status
sudo /opt/zoe-livesync-server/manage.sh logs
sudo /opt/zoe-livesync-server/manage.sh restart
sudo /opt/zoe-livesync-server/manage.sh renew
sudo /opt/zoe-livesync-server/manage.sh config
sudo /opt/zoe-livesync-server/manage.sh setup-uri
```

## 端口要求

- TCP 80：只在申请和续期 IP 证书时临时使用，不会常驻监听，但届时必须允许公网访问。
- TCP 20000-29999 中最终选中的一个端口：本项目独立的 HTTPS 服务端口。
- TCP 5984：仅监听服务器回环地址，不应在云安全组中开放。

如果 TCP 80 当前被其他服务长期占用，脚本会停止证书申请并显示占用信息，不会停止原服务。后续会增加与其他入口共用 HTTP-01 验证目录的可选模式。

## 与已有代理节点共存

假设原代理节点正在使用：

```text
已有域名 → 服务器 IP:443
```

本项目会选择另一个端口：

```text
Obsidian LiveSync → https://服务器IP:随机端口
```

两套服务由各自的进程和配置管理。新脚本不会查找旧项目的注释、路由目录或配置文件。

## 当前边界

- 第一版只处理 Server A（CouchDB 同步端）。Server C 发布端将在后续模块实现。
- 第一版自动证书流程只支持公网 IPv4。
- 云服务器安全组需要放行最终选择的 HTTPS 端口。
- IP 变化后，证书和客户端连接地址需要重新生成。
- 端到端加密口令由用户在 Self-hosted LiveSync 中另行设置并保管。

## 固定版本与上游依据

- CouchDB：`3.5.2.1`
- Caddy：`2.11.4-alpine`
- CouchDB 初始化逻辑依据 Self-hosted LiveSync 官方仓库提交 `2c2b9c90e4e10a454f2838c63ba656c0e67a374c` 重写。
