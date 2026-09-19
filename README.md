# Zoe LiveSync Server

完全独立的一键安装项目，为 Obsidian Self-hosted LiveSync 部署 CouchDB、独立 Caddy 入口和 Let's Encrypt 公网 IP 短期证书。

本项目不依赖、读取或修改任何旧项目，也不改写服务器上已有的 Caddy、Nginx 或代理节点配置。

## 当前功能

- 启动后检查 Linux 发行版、版本、架构、Docker 和 Compose。
- Debian 12/13、Ubuntu 22.04/24.04/26.04 走 Docker 官方源直接安装。
- Debian 11、Ubuntu 18.04 等旧系统及其他 Linux 尝试走发行版软件包兼容安装；若发行版仓库无法提供可用的 Docker/Compose，会明确停止并提示先按该发行版文档安装 Docker。
- 已有可用 Docker + Compose 时，不限制 Linux 发行版。
- 从多个直连公网查询和云厂商元数据收集公网 IPv4 候选。
- 不显示或接受局域网、CGNAT、回环、文档示例及其他保留地址。
- 候选 IP 不一致时明确警告，由用户确认，不静默猜测。
- 使用 `acme.sh` 和 Let's Encrypt `shortlived` profile 签发公网 IP 证书。
- 默认从 `20000-29999` 随机选择一个未占用的独立 HTTPS 端口，并在安装结束时醒目显示。
- 重跑时如果上次自动保存的端口已被其他服务占用，会重新随机选择；用户明确指定的端口被占用时则停止，避免擅自改动指定配置。
- 检测到已启用的 UFW 或 firewalld 时，自动、持久放行 TCP 80 和最终选中的 HTTPS 端口。
- 不停止、不改写、不接管服务器上已有的代理节点。
- 使用项目独立的 acme.sh 目录，每 12 小时只检查本项目 IP 证书；不删除、改写或调用服务器已有的 acme.sh 证书任务。证书更新后自动重载本项目自己的 Caddy。
- CouchDB 仅绑定 `127.0.0.1:5984`，不会把数据库原始端口暴露到公网。
- 自动配置 Self-hosted LiveSync 所需的 CORS、认证和大小限制，并使用固定版本的 LiveSync Commonlib 初始化、验证数据库版本。
- CouchDB 初始化同步等待并检查退出状态；初始化失败时不会继续显示安装成功。
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

如需由你自己管理主机防火墙，可明确跳过自动配置：

```bash
sudo FIREWALL_MODE=skip bash install.sh
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
sudo /opt/zoe-livesync-server/manage.sh uri
```

`manage.sh uri` 只输出一行完整的 Setup URI。也可以直接打开：

```text
/opt/zoe-livesync-server/setup-uri-only.txt
```

该文件不含标题、说明或保护口令，可以全选后直接粘贴到 Self-hosted LiveSync。脚本会在写出文件前确认 URI 以 `obsidian://setuplivesync?settings=` 开始、整行不含空白字符，并使用同一套官方库反向解密，核对服务器地址、数据库名、用户名、密码、Vault 加密口令及加密状态。加密载荷没有应当硬编码的固定结尾；反向解密校验可以同时发现载荷截断和字段缺失。

安装结束页还会把 URI 中的关键配置解说为可读内容，包括 CouchDB 地址、数据库名、账号、密码、Vault 加密口令、启动同步、60 秒周期复制、文件打开/合并后的同步触发、批量写入方式和活动远程类型。Setup URI 保护口令不在 URI 内，会单独醒目标示。

## 端口要求

- TCP 80：只在申请和续期 IP 证书时临时使用，不会常驻监听，但届时必须允许公网访问。
- TCP 20000-29999 中最终选中的一个端口：本项目独立的 HTTPS 服务端口。
- TCP 5984：仅监听服务器回环地址，不应在云安全组中开放。

脚本只处理服务器操作系统内部的防火墙：

- UFW 已启用：自动添加 TCP 80 和随机 HTTPS 端口规则。
- firewalld 已运行：先根据公网默认路由查出实际出口网卡，再向该网卡所属区域添加即时规则和永久规则；没有显式区域时使用默认区域。
- UFW/firewalld 未启用：不会擅自安装或开启防火墙。
- 检测到自定义 nftables/iptables 默认拒绝入站：只给出警告，不直接改写规则，以免影响已有代理或其他服务。

云厂商控制台中的“安全组”在服务器外部，通用脚本没有云账号 API 权限，无法自动修改。仍需在云服务商控制台确认 TCP 80 和最终选中的 HTTPS 端口已放行；TCP 5984 不要放行。

如果 TCP 80 当前被其他服务长期占用，脚本会停止证书申请并显示占用信息，不会停止原服务。后续会增加与其他入口共用 HTTP-01 验证目录的可选模式。

安装前还会检查本机 `127.0.0.1:5984`。如果它由本项目 CouchDB 使用，可以安全重跑；如果由其他进程或容器使用，脚本会停止，避免覆盖或接管既有数据库。

安装结束时，脚本首先通过 `127.0.0.1` 配合公网 IP 的证书名称验证 Caddy、TLS 和 CouchDB，不依赖云厂商是否支持“服务器访问自己的公网 IP”。随后会尝试公网回环检查；该检查失败只会提示从手机网络复核，不会把不支持回环误判为安装失败。

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
- 云服务器安全组需要放行 TCP 80 和最终选择的 HTTPS 端口。
- IP 变化后，证书和客户端连接地址需要重新生成。
- 端到端加密口令由用户在 Self-hosted LiveSync 中另行设置并保管。

## 固定版本与上游依据

- CouchDB：`3.5.2.1`
- Caddy：`2.11.4-alpine`
- CouchDB 初始化逻辑依据 Self-hosted LiveSync 官方仓库提交 `2c2b9c90e4e10a454f2838c63ba656c0e67a374c` 重写，LiveSync Commonlib 固定为 `0.1.0-rc.4`。
