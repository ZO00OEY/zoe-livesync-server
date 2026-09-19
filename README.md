# Zoe LiveSync Server

为 Obsidian Self-hosted LiveSync 部署 CouchDB，并根据服务器现状选择独立 IP 证书或接入现有 Caddy。

这是全新实现，参考了 [`ip-ssl-proxy`](https://github.com/ZO00OEY/ip-ssl-proxy) 的 IP 证书流程，以及 Self-hosted LiveSync 官方的 CouchDB 配置方式。

## 当前功能

- 启动后检查 Linux 发行版、版本、架构、Docker 和 Compose。
- Debian 12/13、Ubuntu 22.04/24.04/26.04 走 Docker 官方源直接安装。
- Debian 11、Ubuntu 18.04 等旧系统及其他 Linux 走发行版软件包兼容安装。
- 已有可用 Docker + Compose 时，不限制 Linux 发行版。
- 从多个直连公网查询和云厂商元数据收集公网 IPv4 候选。
- 不显示或接受局域网、CGNAT、回环、文档示例及其他保留地址。
- 候选 IP 不一致时明确警告，由用户确认，不静默猜测。
- 空服务器使用 `acme.sh` 和 Let's Encrypt `shortlived` profile 签发公网 IP 证书。
- 80/443 已由现有 Caddy 使用时，复用现有 HTTPS 入口并增加 `/couchdb/` 路由，不启动第二个 Caddy。
- 80/443 被其他程序占用时安全退出，不停止或覆盖现有代理节点。
- 独立模式每 12 小时检查续期；证书更新后自动重载 Caddy。
- CouchDB 仅绑定 `127.0.0.1:5984`，公网只开放 80/443。
- 自动配置 Self-hosted LiveSync 所需的 CORS、认证和大小限制。
- 生成可直接填写到 Self-hosted LiveSync 的连接信息。

## 一键安装

```bash
git clone https://github.com/ZO00OEY/zoe-livesync-server.git
cd zoe-livesync-server
sudo bash install.sh
```

空服务器上，脚本会列出经过过滤的公网 IPv4 候选。已有 Caddy 时会优先读取现有入口，不再申请第二张证书。

如果服务器使用了代理，并且你已经确认实际入站公网 IP：

```bash
sudo PUBLIC_IP=203.0.113.10 bash install.sh
```

上面的 `203.0.113.10` 是文档示例地址，实际运行时会被脚本拒绝；请换成服务器真实公网 IP。

非交互安装必须明确指定 IP：

```bash
sudo PUBLIC_IP=你的公网IP NON_INTERACTIVE=1 bash install.sh --non-interactive
```

## IP 检测测试

只检查公网 IP，不安装任何服务：

```bash
bash install.sh --detect-ip
```

此模式也不会显示局域网地址。

## 安装后的连接信息

```text
Remote type: CouchDB
URI: https://公网IP
# 或复用现有入口：https://已有域名/couchdb
Username: 自动生成/指定的用户名
Password: 自动生成/指定的密码
Database: obsidiannotes
```

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
```

## 端口要求

- 独立模式需要 TCP 80/443。
- 现有 Caddy 模式复用已经监听的 80/443，不创建新的端口监听者。
- 5984：仅监听服务器回环地址，不应在云安全组中开放。

如果 80/443 是现有 Caddy，脚本会尝试复用其 `/couchdb/` 路由；如果是其他服务则停止，不会杀死或接管它。

## 当前边界

- 第一版只处理 Server A（CouchDB 同步端）。Server C 发布端将在后续模块实现。
- 第一版自动证书流程只支持公网 IPv4；IPv6 将在实际服务器验证后加入。
- IP 变化后，证书和所有客户端连接地址都需要更新。
- 脚本生成的是服务器连接参数；端到端加密口令由用户在 Self-hosted LiveSync 中另行设置并保管。

## 来源与固定版本

- CouchDB：`3.5.2.1`
- Caddy：`2.11.4-alpine`
- CouchDB 初始化逻辑参考 Self-hosted LiveSync 官方仓库提交 `2c2b9c90e4e10a454f2838c63ba656c0e67a374c`。
- IP 证书逻辑参考本人的 `ip-ssl-proxy`，但已重写 IP 过滤、容器隔离和安装流程。
