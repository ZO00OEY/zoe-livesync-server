# Zoe LiveSync Server

完全独立的一键安装项目，为 Obsidian 第三方社区插件 Self-hosted LiveSync 部署 CouchDB、独立 Caddy 入口和 HTTPS 证书。

本项目不依赖任何旧项目，也不改写服务器上已有的 Caddy、Nginx、Headscale 或代理节点配置。自动复用证书时只读取现有 HTTPS 端点、常见证书目录和相关 Docker 挂载，用于寻找可验证的证书与私钥。

## 换电脑后从这里继续

代码和说明都在 GitHub，换电脑不需要复制本机的 `F:\claude` 目录：

```bash
git clone https://github.com/ZO00OEY/zoe-livesync-server.git
cd zoe-livesync-server
git pull --ff-only
```

如果目标服务器已经克隆过仓库，更新源码后必须重新运行安装脚本，才会把新版管理脚本和配置复制到 `/opt/zoe-livesync-server`：

```bash
cd ~/zoe-livesync-server && git pull --ff-only && sudo bash install.sh
```

Git 仓库不包含服务器上的密码、证书私钥、CouchDB 数据和生成后的 Setup URI。已经安装过时，请在服务器上查看：

```bash
sudo /opt/zoe-livesync-server/manage.sh status
sudo /opt/zoe-livesync-server/manage.sh config
```

开始前需要一台有公网 IPv4 的 Linux 服务器、root/sudo 权限和可用的出站 HTTPS。域名不是必需项。云厂商安全组仍需在控制台中手动放行脚本最终提示的端口。

## 两种证书模式

| 场景 | 脚本行为 | 需要放行 | 谁负责续签 |
| --- | --- | --- | --- |
| 已有可复用证书 | 验证域名/IP、证书和私钥，复制给 Zoe 的独立 Caddy | 随机 HTTPS 端口 | 原证书系统续签；Zoe 每 12 小时安全同步并重载自己的 Caddy |
| 没有可复用证书 | TCP 80 空闲时，用隔离的 acme.sh 申请公网 IP 短期证书 | TCP 80 和随机 HTTPS 端口 | Zoe 的 acme.sh |

两种模式的客户端地址都是 `https://域名或公网IP:随机端口`，不使用 `/couchdb` 子路径。CouchDB 本身始终只暴露在服务器回环地址。若没有可复用证书且 TCP 80 已被占用，脚本会退出，不会停止现有服务。

## 当前功能

- 启动后检查 Linux 发行版、版本、架构、Docker 和 Compose。
- 基础工具已经完整时跳过包管理器更新和重复安装。
- Debian 12/13、Ubuntu 22.04/24.04/26.04 走 Docker 官方源直接安装。
- Debian 11、Ubuntu 18.04 等旧系统及其他 Linux 尝试走发行版软件包兼容安装；若发行版仓库无法提供可用的 Docker/Compose，会明确停止并提示先按该发行版文档安装 Docker。
- 已有可用 Docker + Compose 时，不限制 Linux 发行版。
- 从多个直连公网查询和云厂商元数据收集公网 IPv4 候选。
- 不显示或接受局域网、CGNAT、回环、文档示例及其他保留地址。
- 候选 IP 不一致时明确警告，由用户确认，不静默猜测。
- 重跑时优先显示上次确认的公网 IP，同时重新检测并要求确认；上次结果与本次建议不一致时醒目警告。
- 证书只有两种模式，且都由本项目独立 Caddy 提供 HTTPS：复用现有证书，或在 TCP 80 空闲时签发公网 IP 证书。
- 443 已有 HTTPS 服务时，尝试识别其域名或公网 IP 证书；仅在证书、私钥和服务器地址全部匹配后询问是否复用。
- 默认从 `20000-29999` 随机选择一个未占用的独立 HTTPS 端口，并在安装结束时醒目显示。
- 重跑时如果上次自动保存的端口已被其他服务占用，会重新随机选择；用户明确指定的端口被占用时则停止，避免擅自改动指定配置。
- 检测到已启用的 UFW 或 firewalld 时，自动、持久放行实际需要的端口；复用证书时不额外开放 TCP 80。
- 不停止、不改写、不接管服务器上已有的代理节点；没有可复用证书且 TCP 80 被占用时会显示占用者并退出。
- IP 证书模式使用项目独立的 acme.sh 目录，不删除、改写或调用服务器已有的 acme.sh 任务。统一的 12 小时检查任务只维护本项目证书；发现更新后自动重载本项目自己的 Caddy。
- CouchDB 仅绑定 `127.0.0.1:5984`，不会把数据库原始端口暴露到公网。
- 直接调用固定提交的 Self-hosted LiveSync 上游 provisioning，配置 CORS、认证和大小限制，并初始化、验证数据库版本。
- CouchDB 初始化同步等待并检查退出状态；初始化失败时不会继续显示安装成功。
- 生成可直接填写到 Self-hosted LiveSync 的连接信息。

## 一键安装

```bash
git clone https://github.com/ZO00OEY/zoe-livesync-server.git
cd zoe-livesync-server
sudo bash install.sh
```

运行过程中通常只需要确认公网 IP；如果发现可安全复用的现有证书，还会询问是否复用。安装成功前，脚本会验证 CouchDB、Caddy、证书和本机 HTTPS 链路，不会只凭容器启动就报告成功。

脚本会确认公网 IPv4，并随机选择不冲突的 HTTPS 端口，例如：

```text
https://公网IP:随机端口
```

如果检测到可安全复用的现有域名或公网 IP 证书，也可以得到：

```text
https://现有域名或公网IP:随机端口
```

如果需要明确指定：

```bash
sudo PUBLIC_IP=你的公网IP HTTPS_PORT=8443 bash install.sh
```

也可以明确指定要复用的现有证书。三个参数必须同时提供，脚本会检查有效期、域名或公网 IP、服务器地址和私钥是否匹配：

```bash
sudo PUBLIC_HOST=sync.example.com \
  TLS_CERT_FILE=/etc/letsencrypt/live/sync.example.com/fullchain.pem \
  TLS_KEY_FILE=/etc/letsencrypt/live/sync.example.com/privkey.pem \
  bash install.sh
```

如果证书包含当前公网 IP 的 IP SAN，`PUBLIC_HOST` 也可直接填写该公网 IP。

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

完整信息分别保存在：

```text
/opt/zoe-livesync-server/connection.txt
/opt/zoe-livesync-server/setup-uri.txt
/opt/zoe-livesync-server/setup-uri-only.txt
```

这些文件和 `.env` 权限均为 `600`，不要提交或公开发送。`setup-uri-only.txt` 只有一行 URI；解密它所需的 Setup URI 保护口令在 `setup-uri.txt` 中。

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

该文件不含标题、说明或保护口令，可以全选后直接粘贴到 Self-hosted LiveSync。脚本会在写出文件前确认 URI 以 `obsidian://setuplivesync?settings=` 开始、整行不含空白字符，并使用 Self-hosted LiveSync 上游项目采用的库反向解密，核对服务器地址、数据库名、用户名、密码、Vault 加密口令及加密状态。加密载荷没有应当硬编码的固定结尾；反向解密校验可以同时发现载荷截断和字段缺失。

安装结束页还会把 URI 中的关键配置解说为可读内容，包括 CouchDB 地址、数据库名、账号、密码、Vault 加密口令、启动同步、60 秒周期复制、文件打开/合并后的同步触发、批量写入方式和活动远程类型。Setup URI 保护口令不在 URI 内，会单独醒目标示。

## 端口要求

- TCP 80：只在申请和续期 IP 证书时临时使用；复用现有证书时不需要。
- TCP 20000-29999 中最终选中的一个端口：本项目独立的 HTTPS 服务端口。
- TCP 5984：仅监听服务器回环地址，不应在云安全组中开放。

脚本只处理服务器操作系统内部的防火墙：

- UFW 已启用：自动添加当前模式需要的规则；IP 证书模式放行 TCP 80 和随机 HTTPS 端口，复用证书模式只放行随机 HTTPS 端口。
- firewalld 已运行：先根据公网默认路由查出实际出口网卡，再向该网卡所属区域添加即时规则和永久规则；没有显式区域时使用默认区域。
- UFW/firewalld 未启用：不会擅自安装或开启防火墙。
- 检测到自定义 nftables/iptables 默认拒绝入站：只给出警告，不直接改写规则，以免影响已有代理或其他服务。

云厂商控制台中的“安全组”在服务器外部，通用脚本没有云账号 API 权限，无法自动修改。IP 证书模式需确认 TCP 80 和最终 HTTPS 端口已放行；复用证书时只需放行最终 HTTPS 端口。TCP 5984 不要放行。

如果 TCP 80 被占用，脚本会检查 443 上各个候选域名实际提供的证书，再在常见证书目录和占用 443 的 Docker 容器挂载中查找匹配私钥。只有域名解析到本机公网 IP，或证书直接包含该公网 IP，且线上证书、磁盘证书和私钥全部匹配时才会建议复用。Let’s Encrypt 自动发现会优先保存 `live/...` 稳定路径，避免续期后仍盯着 `archive/...` 历史文件。

复用模式不会接管原证书的签发和续期。脚本每 12 小时检查一次源证书；先把证书和私钥复制到临时区并重新验证，确认是同一对后才替换本项目副本。仅在内容更新后平滑重载本项目 Caddy，CouchDB 不会因此重启。

如果没有可复用证书且 TCP 80 已被占用，脚本会显示监听进程并退出，不会停止容器、systemd 服务或直接结束 PID。用户处理好证书或端口后可以安全重跑。

安装前还会检查本机 `127.0.0.1:5984`。如果它由本项目 CouchDB 使用，可以安全重跑；如果由其他进程或容器使用，脚本会停止，避免覆盖或接管既有数据库。

安装结束时，脚本首先通过 `127.0.0.1` 配合最终域名或公网 IP 验证 Caddy、TLS 和 CouchDB，不依赖云厂商是否支持“服务器访问自己的公网 IP”。随后会尝试公网回环检查；该检查失败只会提示从手机网络复核，不会把不支持回环误判为安装失败。

## 与已有代理节点共存

假设原代理节点正在使用：

```text
已有域名 → 服务器 IP:443
```

本项目会选择另一个端口：

```text
Obsidian LiveSync → https://服务器IP或已有域名:随机端口
```

两套服务由各自的进程和配置管理。新脚本不会查找旧项目的注释、路由目录或配置文件。

## 常见问题与安全退出

- **80 和 443 已被 Headscale 等容器占用**：脚本先尝试复用 443 正在使用的证书。能找到对应私钥就继续使用随机端口；找不到就安全退出，Headscale 不会被停止。
- **提示找不到可复用证书**：可以确认原服务是否把证书和私钥挂载到了宿主机，再通过 `PUBLIC_HOST`、`TLS_CERT_FILE`、`TLS_KEY_FILE` 明确指定。不要为了安装本项目直接删除原容器。
- **外网打不开、但本机验证通过**：在云厂商安全组中放行安装结果显示的随机 TCP 端口；IP 证书模式还要放行 TCP 80。不要开放 TCP 5984。
- **证书同步或续期失败**：运行 `sudo /opt/zoe-livesync-server/manage.sh renew` 查看即时错误，再运行 `status`；失败记录保存在 `/opt/zoe-livesync-server/certificate-renewal-failed.txt`。
- **重复运行安装脚本**：会重新确认公网 IP，保留已有数据库卷和已生成密码；已完整的基础工具和 Docker 会跳过，不会清空 CouchDB。
- **需要查看日志**：运行 `sudo /opt/zoe-livesync-server/manage.sh logs`，或在后面加 `couchdb`、`caddy` 查看单个服务。

## 当前边界

- 第一版只处理 Server A（CouchDB 同步端）。Server C 发布端将在后续模块实现。
- 自动 IP 证书流程只支持公网 IPv4；现有证书模式支持解析到该 IPv4 的普通域名，或证书 IP SAN 中的该公网 IPv4。
- IP 证书模式需要放行 TCP 80 和最终 HTTPS 端口；复用证书时只需最终 HTTPS 端口。
- IP 变化后，证书和客户端连接地址需要重新生成。
- 安装器会生成并写入 Setup URI 的 Vault 端到端加密口令；必须与 Setup URI 保护口令分清并妥善保存。

## 固定版本与上游依据

- CouchDB：`3.5.2.1`
- Caddy：`2.11.4-alpine`
- CouchDB 初始化直接调用第三方社区插件 Self-hosted LiveSync 的上游仓库提交 `2c2b9c90e4e10a454f2838c63ba656c0e67a374c`。这里的“上游”不代表 Obsidian 官方服务或 Obsidian Sync。
