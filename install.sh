#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="Zoe LiveSync Server"
INSTALL_DIR="${ZOE_INSTALL_DIR:-/opt/zoe-livesync-server}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME_BIN="${ACME_HOME}/acme.sh"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
PUBLIC_IP="${PUBLIC_IP:-}"
COUCHDB_USER="${COUCHDB_USER:-obsidian_user}"
COUCHDB_DATABASE="${COUCHDB_DATABASE:-obsidiannotes}"

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[1;33m'; cyan='\033[0;36m'; reset='\033[0m'
info() { printf "%b[信息]%b %s\n" "${cyan}" "${reset}" "$*"; }
ok() { printf "%b[完成]%b %s\n" "${green}" "${reset}" "$*"; }
warn() { printf "%b[注意]%b %s\n" "${yellow}" "${reset}" "$*" >&2; }
die() { printf "%b[错误]%b %s\n" "${red}" "${reset}" "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

valid_ipv4() {
    local ip="$1" IFS=. octets octet
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    read -r -a octets <<< "${ip}"
    for octet in "${octets[@]}"; do
        [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#${octet} <= 255 )) || return 1
    done
}

is_public_ipv4() {
    local ip="$1" a b c
    valid_ipv4 "${ip}" || return 1
    IFS=. read -r a b c _ <<< "${ip}"

    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 192 && b == 0 && c == 0 )) && return 1
    (( a == 192 && b == 0 && c == 2 )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    return 0
}

trim_ip() {
    printf '%s' "$1" | tr -d '[:space:]'
}

direct_curl() {
    env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
        curl --noproxy '*' -4 -fsS --connect-timeout 2 --max-time 4 "$@" 2>/dev/null
}

add_ip_candidate() {
    local source="$1" value
    value="$(trim_ip "${2:-}")"
    if is_public_ipv4 "${value}"; then
        IP_SOURCES+=("${source}")
        IP_VALUES+=("${value}")
    fi
}

collect_ip_candidates() {
    IP_SOURCES=()
    IP_VALUES=()
    local value token

    add_ip_candidate "ipify（直连）" "$(direct_curl https://api.ipify.org || true)"
    add_ip_candidate "AWS checkip（直连）" "$(direct_curl https://checkip.amazonaws.com || true)"
    add_ip_candidate "icanhazip（直连）" "$(direct_curl https://ipv4.icanhazip.com || true)"
    add_ip_candidate "Cloudflare trace（直连）" "$(direct_curl https://1.1.1.1/cdn-cgi/trace | awk -F= '$1=="ip" {print $2}' || true)"

    token="$(curl --noproxy '*' -fsS -X PUT --connect-timeout 1 --max-time 2 \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        http://169.254.169.254/latest/api/token 2>/dev/null || true)"
    if [[ -n "${token}" ]]; then
        value="$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 \
            -H "X-aws-ec2-metadata-token: ${token}" \
            http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
        add_ip_candidate "AWS 元数据" "${value}"
    fi
    add_ip_candidate "Google Cloud 元数据" "$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 \
        -H 'Metadata-Flavor: Google' \
        'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' 2>/dev/null || true)"

    while read -r value; do
        add_ip_candidate "本机公网网卡" "${value}"
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' || true)
}

choose_ip_candidate() {
    local i value answer best_ip="" best_count=0 source_list
    declare -A counts=()
    declare -A sources=()
    local -a unique_ips=()

    if [[ -n "${PUBLIC_IP}" ]]; then
        is_public_ipv4 "${PUBLIC_IP}" || die "PUBLIC_IP=${PUBLIC_IP} 不是可用的公网 IPv4 地址。"
        return
    fi

    collect_ip_candidates
    ((${#IP_VALUES[@]} > 0)) || die "没有检测到公网 IPv4；可用 PUBLIC_IP=公网IP 指定。"

    for i in "${!IP_VALUES[@]}"; do
        value="${IP_VALUES[$i]}"
        if [[ -z "${counts["${value}"]+x}" ]]; then
            unique_ips+=("${value}")
        fi
        counts["${value}"]=$(( ${counts["${value}"]:-0} + 1 ))
        source_list="${sources["${value}"]:-}"
        sources["${value}"]="${source_list:+${source_list}、}${IP_SOURCES[$i]}"
        if (( counts["${value}"] > best_count )); then
            best_ip="${value}"
            best_count="${counts["${value}"]}"
        fi
    done

    echo
    echo "检测到以下公网 IPv4 候选（局域网、CGNAT、回环及保留地址已过滤）："
    for i in "${!unique_ips[@]}"; do
        value="${unique_ips[$i]}"
        printf '  %d) %s\n     来源：%s\n' "$((i + 1))" "${value}" "${sources["${value}"]}"
    done
    echo
    if ((${#counts[@]} > 1)); then
        warn "不同来源结果不一致，可能存在代理、透明网关或多出口网络。"
    fi
    printf '建议使用: %s（%d 个来源一致）\n' "${best_ip}" "${best_count}"

    if [[ "${NON_INTERACTIVE}" == "1" || ! -r /dev/tty ]]; then
        die "非交互模式不会替你确认候选 IP；请重新运行 PUBLIC_IP=${best_ip} NON_INTERACTIVE=1 bash install.sh"
    fi

    read -r -p "回车确认，输入候选序号，或输入正确的公网 IPv4: " answer </dev/tty
    if [[ -z "${answer}" ]]; then
        PUBLIC_IP="${best_ip}"
    elif [[ "${answer}" =~ ^[0-9]+$ ]] && (( 10#${answer} >= 1 && 10#${answer} <= ${#unique_ips[@]} )); then
        PUBLIC_IP="${unique_ips[$((10#${answer} - 1))]}"
    else
        is_public_ipv4 "${answer}" || die "输入值不是可用的公网 IPv4 地址。"
        PUBLIC_IP="${answer}"
    fi
    ok "已确认公网 IP：${PUBLIC_IP}"
}

detect_system() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-${OS_ID} ${OS_VERSION}}"
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64|amd64|aarch64|arm64) ;;
        *) die "暂不支持 CPU 架构：${ARCH}" ;;
    esac

    INSTALL_MODE="compatibility"
    case "${OS_ID}:${OS_VERSION}" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04)
            INSTALL_MODE="direct"
            ;;
    esac
    info "系统：${OS_NAME} / ${ARCH}"
    info "安装路径：$([[ "${INSTALL_MODE}" == direct ]] && echo '官方直接安装' || echo '兼容性安装')"
}

install_base_packages() {
    if command_exists apt-get; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl iproute2 cron gnupg
    elif command_exists dnf; then
        dnf install -y curl ca-certificates openssl iproute cronie
    elif command_exists yum; then
        yum install -y curl ca-certificates openssl iproute cronie
    elif command_exists zypper; then
        zypper --non-interactive install curl ca-certificates openssl iproute2 cron
    elif command_exists pacman; then
        pacman -Sy --noconfirm curl ca-certificates openssl iproute2 cronie
    elif command_exists apk; then
        apk add --no-cache bash curl ca-certificates openssl iproute2 docker docker-cli-compose
    else
        die "未识别包管理器，请先安装 curl、openssl、iproute2、cron、Docker 和 Compose。"
    fi
}

docker_ready() {
    command_exists docker && docker info >/dev/null 2>&1 && \
        (docker compose version >/dev/null 2>&1 || command_exists docker-compose)
}

install_docker_direct() {
    info "通过 Docker 官方软件源安装 Docker Engine。"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename
    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ -n "${codename}" ]] || die "无法确定系统代号。"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "${OS_ID}" "${codename}" > /etc/apt/sources.list.d/docker.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_compose_fallback() {
    command_exists docker-compose && return 0
    local arch url
    case "${ARCH}" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
    esac
    url="https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-${arch}"
    curl -fsSL "${url}" -o /usr/local/bin/docker-compose
    chmod 0755 /usr/local/bin/docker-compose
}

install_docker_compatibility() {
    warn "当前系统不在直接安装白名单，将使用发行版软件包兼容安装。"
    if command_exists apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || true
    elif command_exists dnf; then
        dnf install -y docker docker-compose-plugin || dnf install -y moby-engine docker-compose-plugin || true
    elif command_exists yum; then
        yum install -y docker || true
    elif command_exists zypper; then
        zypper --non-interactive install docker docker-compose || true
    elif command_exists pacman; then
        pacman -S --noconfirm docker docker-compose || true
    elif command_exists apk; then
        apk add --no-cache docker docker-cli-compose || true
    fi
    command_exists docker || die "兼容安装未能提供 Docker，请先按当前发行版文档安装 Docker 后重跑。"
    docker compose version >/dev/null 2>&1 || install_compose_fallback
}

ensure_docker() {
    if docker_ready; then
        ok "Docker 与 Compose 已可用，跳过安装。"
        return
    fi
    if command_exists docker; then
        command_exists systemctl && systemctl enable --now docker >/dev/null 2>&1 || true
        if docker info >/dev/null 2>&1; then
            if [[ "${INSTALL_MODE}" == "direct" ]] && command_exists apt-get; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || true
            fi
            docker compose version >/dev/null 2>&1 || install_compose_fallback
            docker_ready && { ok "保留现有 Docker，仅补齐 Compose。"; return; }
        fi
    fi
    docker_ready && return

    if [[ "${INSTALL_MODE}" == "direct" ]]; then
        install_docker_direct
    else
        install_docker_compatibility
    fi
    command_exists systemctl && systemctl enable --now docker >/dev/null 2>&1 || true
    docker_ready || die "Docker 或 Compose 安装后不可用。"
    docker run --rm hello-world >/dev/null 2>&1 || die "Docker 运行验证失败。"
    ok "Docker 安装和运行验证通过。"
}

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose --project-directory "${INSTALL_DIR}" -f "${INSTALL_DIR}/compose.yaml" "$@"
    else
        docker-compose --project-directory "${INSTALL_DIR}" -f "${INSTALL_DIR}/compose.yaml" "$@"
    fi
}

foreign_port_owner() {
    local port="$1"
    if ss -H -ltnp "sport = :${port}" 2>/dev/null | grep -q .; then
        if ! docker ps --format '{{.Names}}' | grep -qx 'zoe-livesync-caddy'; then
            return 0
        fi
    fi
    return 1
}

prepare_files() {
    mkdir -p "${INSTALL_DIR}"/{config,scripts,certs,acme-webroot}
    install -m 0644 "${SOURCE_DIR}/compose.yaml" "${INSTALL_DIR}/compose.yaml"
    install -m 0644 "${SOURCE_DIR}/config/livesync.ini" "${INSTALL_DIR}/config/livesync.ini"
    install -m 0755 "${SOURCE_DIR}/scripts/couchdb-init.sh" "${INSTALL_DIR}/scripts/couchdb-init.sh"
    install -m 0755 "${SOURCE_DIR}/manage.sh" "${INSTALL_DIR}/manage.sh"

    local password="${COUCHDB_PASSWORD:-}" confirmed_ip="${PUBLIC_IP}"
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        # shellcheck source=/dev/null
        source "${INSTALL_DIR}/.env"
        password="${COUCHDB_PASSWORD}"
    fi
    PUBLIC_IP="${confirmed_ip}"
    [[ -n "${password}" ]] || password="$(openssl rand -hex 32)"
    cat > "${INSTALL_DIR}/.env" <<EOF
COUCHDB_USER=${COUCHDB_USER}
COUCHDB_PASSWORD=${password}
COUCHDB_DATABASE=${COUCHDB_DATABASE}
PUBLIC_IP=${PUBLIC_IP}
EOF
    chmod 0600 "${INSTALL_DIR}/.env"
    COUCHDB_PASSWORD="${password}"
}

write_http_caddyfile() {
    cat > "${INSTALL_DIR}/config/Caddyfile" <<'EOF'
{
    auto_https off
}

:80 {
    root * /srv/acme
    file_server
}
EOF
}

write_https_caddyfile() {
    cat > "${INSTALL_DIR}/config/Caddyfile" <<EOF
{
    auto_https off
}

:80 {
    handle /.well-known/acme-challenge/* {
        root * /srv/acme
        file_server
    }
    redir https://${PUBLIC_IP}{uri} permanent
}

https://${PUBLIC_IP} {
    tls /certs/fullchain.cer /certs/${PUBLIC_IP}.key
    reverse_proxy couchdb:5984 {
        flush_interval -1
    }
}
EOF
}

install_acme() {
    if [[ -x "${ACME_BIN}" ]]; then
        ok "acme.sh 已安装。"
        return
    fi
    info "安装 acme.sh。"
    if [[ -n "${ACME_EMAIL:-}" ]]; then
        curl -fsSL https://get.acme.sh | HOME=/root sh -s email="${ACME_EMAIL}" >/dev/null
    else
        curl -fsSL https://get.acme.sh | HOME=/root sh >/dev/null
    fi
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 安装失败。"
}

issue_certificate() {
    local cert_file="${INSTALL_DIR}/certs/fullchain.cer"
    local key_file="${INSTALL_DIR}/certs/${PUBLIC_IP}.key"

    if [[ -f "${cert_file}" ]] && openssl x509 -checkend 86400 -noout -in "${cert_file}" >/dev/null 2>&1 && \
       openssl x509 -in "${cert_file}" -noout -text | grep -Fq "IP Address:${PUBLIC_IP}"; then
        ok "现有 IP 证书仍有效，跳过首次签发。"
        return
    fi

    info "向 Let's Encrypt 申请短期公网 IP 证书。"
    "${ACME_BIN}" --issue --server letsencrypt -d "${PUBLIC_IP}" \
        --certificate-profile shortlived --webroot "${INSTALL_DIR}/acme-webroot" --ecc --force
    "${ACME_BIN}" --install-cert -d "${PUBLIC_IP}" --ecc \
        --fullchain-file "${cert_file}" --key-file "${key_file}" \
        --reloadcmd "/usr/local/sbin/zoe-livesync-reload"

    openssl x509 -checkend 86400 -noout -in "${cert_file}" >/dev/null 2>&1 || die "签发结果不是有效证书。"
    openssl x509 -in "${cert_file}" -noout -text | grep -Fq "IP Address:${PUBLIC_IP}" || die "证书 SAN 与公网 IP 不匹配。"
    chmod 0644 "${cert_file}"
    chmod 0600 "${key_file}"
}

install_renewal_helpers() {
    cat > /usr/local/sbin/zoe-livesync-reload <<EOF
#!/usr/bin/env bash
set -eu
cd "${INSTALL_DIR}"
if docker compose version >/dev/null 2>&1; then
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
else
    docker-compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
fi
EOF
    cat > /usr/local/sbin/zoe-livesync-renew <<EOF
#!/usr/bin/env bash
set -eu
"${ACME_BIN}" --cron --home "${ACME_HOME}"
openssl x509 -checkend 86400 -noout -in "${INSTALL_DIR}/certs/fullchain.cer"
EOF
    chmod 0755 /usr/local/sbin/zoe-livesync-reload /usr/local/sbin/zoe-livesync-renew
    cat > /etc/cron.d/zoe-livesync-renew <<'EOF'
17 */12 * * * root /usr/local/sbin/zoe-livesync-renew >> /var/log/zoe-livesync-renew.log 2>&1
EOF
    chmod 0644 /etc/cron.d/zoe-livesync-renew
    command_exists systemctl && systemctl enable --now cron >/dev/null 2>&1 || \
        command_exists systemctl && systemctl enable --now crond >/dev/null 2>&1 || true
}

wait_for_couchdb() {
    local i
    for i in {1..60}; do
        if curl -fsS --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" http://127.0.0.1:5984/_up 2>/dev/null | grep -q '"status":"ok"'; then
            return 0
        fi
        sleep 2
    done
    compose logs --tail=100 couchdb couchdb-init >&2 || true
    die "CouchDB 在规定时间内未就绪。"
}

write_connection_file() {
    cat > "${INSTALL_DIR}/connection.txt" <<EOF
Zoe LiveSync / Self-hosted LiveSync 连接信息

Remote type: CouchDB
URI: https://${PUBLIC_IP}
Username: ${COUCHDB_USER}
Password: ${COUCHDB_PASSWORD}
Database: ${COUCHDB_DATABASE}

注意：首次设备请使用一个单独保存的端到端加密口令；它不是上面的 CouchDB 密码。
EOF
    chmod 0600 "${INSTALL_DIR}/connection.txt"
}

verify_installation() {
    compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
    local body
    body="$(curl -fsS --connect-timeout 5 --max-time 15 \
        --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "https://${PUBLIC_IP}/_up")" || die "公网 HTTPS 验证失败；请检查云安全组和 80/443 端口。"
    grep -q '"status":"ok"' <<< "${body}" || die "HTTPS 已响应，但 CouchDB 健康检查内容不正确。"
    ok "HTTPS、证书与 CouchDB 端到端验证通过。"
}

usage() {
    cat <<'EOF'
用法：sudo bash install.sh [--non-interactive] [--detect-ip]

环境变量：
  PUBLIC_IP          明确指定公网 IPv4
  COUCHDB_USER       CouchDB 用户名，默认 obsidian_user
  COUCHDB_PASSWORD   CouchDB 密码；不指定则随机生成
  COUCHDB_DATABASE   数据库名，默认 obsidiannotes
  ZOE_INSTALL_DIR    安装目录，默认 /opt/zoe-livesync-server
EOF
}

main() {
    local detect_only=0
    while (($#)); do
        case "$1" in
            --non-interactive) NON_INTERACTIVE=1 ;;
            --detect-ip) detect_only=1 ;;
            -h|--help) usage; return 0 ;;
            *) die "未知参数：$1" ;;
        esac
        shift
    done

    echo "========================================"
    echo "  ${PROJECT_NAME}"
    echo "========================================"
    choose_ip_candidate
    (( detect_only == 1 )) && { printf '%s\n' "${PUBLIC_IP}"; return 0; }
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 或 sudo 运行。"
    [[ "${COUCHDB_USER}" =~ ^[A-Za-z][A-Za-z0-9_-]{2,31}$ ]] || die "COUCHDB_USER 格式无效。"
    [[ "${COUCHDB_DATABASE}" =~ ^[a-z][a-z0-9_-]{2,63}$ ]] || die "COUCHDB_DATABASE 格式无效。"
    if [[ -n "${COUCHDB_PASSWORD:-}" ]]; then
        [[ "${COUCHDB_PASSWORD}" =~ ^[A-Za-z0-9._~!@%+=:-]{16,128}$ ]] || die "COUCHDB_PASSWORD 需为 16-128 位安全字符。"
    fi
    detect_system
    install_base_packages
    ensure_docker

    foreign_port_owner 80 && die "端口 80 已被其他服务占用；不会自动停止它。"
    foreign_port_owner 443 && die "端口 443 已被其他服务占用；不会自动停止它。"

    prepare_files
    write_http_caddyfile
    compose up -d couchdb couchdb-init caddy
    wait_for_couchdb
    install_acme
    install_renewal_helpers
    issue_certificate
    write_https_caddyfile
    compose up -d
    compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    write_connection_file
    verify_installation

    echo
    echo "安装完成。Self-hosted LiveSync 填写："
    cat "${INSTALL_DIR}/connection.txt"
    echo
    echo "连接信息保存于：${INSTALL_DIR}/connection.txt（权限 600）"
    echo "管理命令：${INSTALL_DIR}/manage.sh status"
}

if [[ "${1:-}" != "--source-only" ]]; then
    main "$@"
fi
