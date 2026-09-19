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
HTTPS_PORT="${HTTPS_PORT:-}"
FIREWALL_MODE="${FIREWALL_MODE:-auto}"
PUBLIC_URL=""
HOST_FIREWALL_STATUS="尚未检查"
VAULT_PASSPHRASE="${VAULT_PASSPHRASE:-}"
SETUP_URI_PASSPHRASE="${SETUP_URI_PASSPHRASE:-}"

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
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl iproute2 cron gnupg socat
    elif command_exists dnf; then
        dnf install -y curl ca-certificates openssl iproute cronie socat
    elif command_exists yum; then
        yum install -y curl ca-certificates openssl iproute cronie socat
    elif command_exists zypper; then
        zypper --non-interactive install curl ca-certificates openssl iproute2 cron socat
    elif command_exists pacman; then
        pacman -Sy --noconfirm curl ca-certificates openssl iproute2 cronie socat
    elif command_exists apk; then
        apk add --no-cache bash curl ca-certificates openssl iproute2 socat dcron docker docker-cli-compose
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
        docker compose -p zoe-livesync --project-directory "${INSTALL_DIR}" -f "${INSTALL_DIR}/compose.yaml" "$@"
    else
        docker-compose -p zoe-livesync --project-directory "${INSTALL_DIR}" -f "${INSTALL_DIR}/compose.yaml" "$@"
    fi
}

port_is_busy() {
    ss -H -ltnp "sport = :$1" 2>/dev/null | grep -q .
}

select_https_port() {
    local stored_port="" candidate random_value
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        stored_port="$(sed -n 's/^HTTPS_PORT=//p' "${INSTALL_DIR}/.env" | head -n 1)"
    fi
    [[ -n "${HTTPS_PORT}" ]] || HTTPS_PORT="${stored_port}"

    if [[ -n "${HTTPS_PORT}" ]]; then
        if [[ ! "${HTTPS_PORT}" =~ ^[0-9]+$ ]] || (( HTTPS_PORT < 1 || HTTPS_PORT > 65535 )); then
            die "HTTPS_PORT 必须是 1-65535 之间的端口。"
        fi
        if port_is_busy "${HTTPS_PORT}"; then
            if ! docker port zoe-livesync-caddy 443/tcp 2>/dev/null | grep -Eq ":${HTTPS_PORT}$"; then
                die "指定的 HTTPS 端口 ${HTTPS_PORT} 已被其他服务占用。"
            fi
        fi
    else
        for _ in {1..100}; do
            random_value="$(od -An -N4 -tu4 /dev/urandom | tr -d '[:space:]')"
            candidate=$((20000 + random_value % 10000))
            if ! port_is_busy "${candidate}"; then
                HTTPS_PORT="${candidate}"
                break
            fi
        done
        [[ -n "${HTTPS_PORT}" ]] || die "连续 100 次都未找到空闲随机端口，请通过 HTTPS_PORT 手动指定。"
    fi

    if [[ "${HTTPS_PORT}" == "443" ]]; then
        PUBLIC_URL="https://${PUBLIC_IP}"
    else
        PUBLIC_URL="https://${PUBLIC_IP}:${HTTPS_PORT}"
    fi
    info "已选定独立随机 HTTPS 端口：${HTTPS_PORT}"
}

custom_firewall_is_restrictive() {
    local input_policy=""

    if command_exists nft && nft list ruleset 2>/dev/null | grep -Eiq 'hook[[:space:]]+input.*policy[[:space:]]+(drop|reject)'; then
        return 0
    fi
    if command_exists iptables; then
        input_policy="$(iptables -S INPUT 2>/dev/null | head -n 1 || true)"
        [[ "${input_policy}" == "-P INPUT DROP" || "${input_policy}" == "-P INPUT REJECT" ]] && return 0
    fi
    return 1
}

configure_host_firewall() {
    local port zone

    case "${FIREWALL_MODE}" in
        auto) ;;
        skip)
            HOST_FIREWALL_STATUS="已按 FIREWALL_MODE=skip 跳过自动配置"
            warn "已跳过主机防火墙配置；请自行确认 TCP 80 和 TCP ${HTTPS_PORT} 可入站。"
            return
            ;;
        *) die "FIREWALL_MODE 只能是 auto 或 skip。" ;;
    esac

    if command_exists ufw && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        for port in 80 "${HTTPS_PORT}"; do
            ufw allow "${port}/tcp" >/dev/null || die "UFW 放行 TCP ${port} 失败。"
        done
        HOST_FIREWALL_STATUS="UFW 已自动放行 TCP 80 和 TCP ${HTTPS_PORT}"
        ok "${HOST_FIREWALL_STATUS}。"
        return
    fi

    if command_exists firewall-cmd && firewall-cmd --state 2>/dev/null | grep -qx 'running'; then
        zone="$(firewall-cmd --get-active-zones 2>/dev/null | awk 'NF && $1 !~ /^(interfaces:|sources:)$/ {print $1; exit}')"
        [[ -n "${zone}" ]] || zone="$(firewall-cmd --get-default-zone)"
        for port in 80 "${HTTPS_PORT}"; do
            firewall-cmd --zone="${zone}" --add-port="${port}/tcp" >/dev/null || die "firewalld 临时放行 TCP ${port} 失败。"
            firewall-cmd --permanent --zone="${zone}" --add-port="${port}/tcp" >/dev/null || die "firewalld 永久放行 TCP ${port} 失败。"
        done
        HOST_FIREWALL_STATUS="firewalld 区域 ${zone} 已自动放行 TCP 80 和 TCP ${HTTPS_PORT}"
        ok "${HOST_FIREWALL_STATUS}。"
        return
    fi

    if custom_firewall_is_restrictive; then
        HOST_FIREWALL_STATUS="检测到自定义 nftables/iptables 入站限制，未自动修改"
        warn "${HOST_FIREWALL_STATUS}；请手动放行 TCP 80 和 TCP ${HTTPS_PORT}。"
    else
        HOST_FIREWALL_STATUS="未检测到启用中的 UFW/firewalld；未新增主机防火墙规则"
        info "${HOST_FIREWALL_STATUS}。"
    fi
}

prepare_files() {
    mkdir -p "${INSTALL_DIR}"/{config,scripts,certs}
    install -m 0644 "${SOURCE_DIR}/compose.yaml" "${INSTALL_DIR}/compose.yaml"
    install -m 0644 "${SOURCE_DIR}/config/livesync.ini" "${INSTALL_DIR}/config/livesync.ini"
    install -m 0755 "${SOURCE_DIR}/scripts/couchdb-init.sh" "${INSTALL_DIR}/scripts/couchdb-init.sh"
    install -m 0755 "${SOURCE_DIR}/scripts/generate-setup-uri.sh" "${INSTALL_DIR}/scripts/generate-setup-uri.sh"
    install -m 0755 "${SOURCE_DIR}/manage.sh" "${INSTALL_DIR}/manage.sh"

    local password="${COUCHDB_PASSWORD:-}" confirmed_ip="${PUBLIC_IP}" confirmed_url="${PUBLIC_URL}" confirmed_port="${HTTPS_PORT}"
    local requested_vault_passphrase="${VAULT_PASSPHRASE}" requested_uri_passphrase="${SETUP_URI_PASSPHRASE}"
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        # shellcheck source=/dev/null
        source "${INSTALL_DIR}/.env"
        password="${COUCHDB_PASSWORD}"
    fi
    PUBLIC_IP="${confirmed_ip}"
    PUBLIC_URL="${confirmed_url}"
    HTTPS_PORT="${confirmed_port}"
    [[ -n "${requested_vault_passphrase}" ]] && VAULT_PASSPHRASE="${requested_vault_passphrase}"
    [[ -n "${requested_uri_passphrase}" ]] && SETUP_URI_PASSPHRASE="${requested_uri_passphrase}"
    [[ -n "${password}" ]] || password="$(openssl rand -hex 32)"
    [[ -n "${VAULT_PASSPHRASE}" ]] || VAULT_PASSPHRASE="$(openssl rand -hex 24)"
    [[ -n "${SETUP_URI_PASSPHRASE}" ]] || SETUP_URI_PASSPHRASE="$(openssl rand -hex 24)"
    cat > "${INSTALL_DIR}/.env" <<EOF
COUCHDB_USER=${COUCHDB_USER}
COUCHDB_PASSWORD=${password}
COUCHDB_DATABASE=${COUCHDB_DATABASE}
PUBLIC_IP=${PUBLIC_IP}
PUBLIC_URL=${PUBLIC_URL}
HTTPS_PORT=${HTTPS_PORT}
VAULT_PASSPHRASE=${VAULT_PASSPHRASE}
SETUP_URI_PASSPHRASE=${SETUP_URI_PASSPHRASE}
EOF
    chmod 0600 "${INSTALL_DIR}/.env"
    COUCHDB_PASSWORD="${password}"
}

write_https_caddyfile() {
    cat > "${INSTALL_DIR}/config/Caddyfile" <<EOF
{
    auto_https off
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
    if port_is_busy 80; then
        ss -H -ltnp 'sport = :80' 2>/dev/null >&2 || true
        die "申请公网 IP 证书需要临时使用 80 端口，但该端口当前被占用；脚本不会停止现有服务。"
    fi
    "${ACME_BIN}" --issue --server letsencrypt -d "${PUBLIC_IP}" \
        --certificate-profile shortlived --standalone --listen-v4 --ecc --force
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
    if docker ps --format '{{.Names}}' | grep -qx zoe-livesync-caddy; then
        docker compose -p zoe-livesync --profile https exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    fi
else
    if docker ps --format '{{.Names}}' | grep -qx zoe-livesync-caddy; then
        docker-compose -p zoe-livesync --profile https exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    fi
fi
EOF
    cat > /usr/local/sbin/zoe-livesync-renew <<EOF
#!/usr/bin/env bash
set -eu
if ss -H -ltn 'sport = :80' 2>/dev/null | grep -q .; then
    echo "80 端口正在使用，跳过本轮 IP 证书续期；未停止任何现有服务"
    exit 1
fi
"${ACME_BIN}" --cron --home "${ACME_HOME}"
openssl x509 -checkend 86400 -noout -in "${INSTALL_DIR}/certs/fullchain.cer"
EOF
    chmod 0755 /usr/local/sbin/zoe-livesync-reload /usr/local/sbin/zoe-livesync-renew
    local current_cron
    current_cron="$(crontab -l 2>/dev/null || true)"
    printf '%s\n' "${current_cron}" | awk '!(index($0, "acme.sh") && index($0, "--cron"))' | \
        sed '/^[[:space:]]*$/d' | crontab -
    cat > /etc/cron.d/zoe-livesync-renew <<'EOF'
17 */12 * * * root /usr/local/sbin/zoe-livesync-renew >> /var/log/zoe-livesync-renew.log 2>&1
EOF
    chmod 0644 /etc/cron.d/zoe-livesync-renew
    command_exists systemctl && systemctl enable --now cron >/dev/null 2>&1 || \
        command_exists systemctl && systemctl enable --now crond >/dev/null 2>&1 || true
    if ! command_exists systemctl && command_exists crond && ! pgrep -x crond >/dev/null 2>&1; then
        crond
    fi
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
第一部分：CouchDB API 连接信息

API 类型: CouchDB
API URL: ${PUBLIC_URL}
HTTPS 端口: ${HTTPS_PORT}
认证方式: HTTP Basic Auth（没有单独的 API Key）
用户名: ${COUCHDB_USER}
密码: ${COUCHDB_PASSWORD}
数据库: ${COUCHDB_DATABASE}

主机防火墙: ${HOST_FIREWALL_STATUS}
云安全组: 通用服务器脚本无法修改，请确认 TCP 80 和 TCP ${HTTPS_PORT} 已放行。
端口说明: TCP 80 用于首次签发及自动续期 IP 证书；TCP ${HTTPS_PORT} 用于 LiveSync HTTPS 连接。

注意：首次设备请使用一个单独保存的端到端加密口令；它不是上面的 CouchDB 密码。
EOF
    chmod 0600 "${INSTALL_DIR}/connection.txt"
}

verify_installation() {
    compose --profile https exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
    local body
    body="$(curl -fsS --connect-timeout 5 --max-time 15 \
        --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${PUBLIC_URL}/_up")" || die "公网 HTTPS 验证失败；请确认云安全组已放行 ${HTTPS_PORT}/TCP。"
    grep -q '"status":"ok"' <<< "${body}" || die "HTTPS 已响应，但 CouchDB 健康检查内容不正确。"
    ok "HTTPS、证书与 CouchDB 端到端验证通过。"
}

usage() {
    cat <<'EOF'
用法：sudo bash install.sh [--non-interactive] [--detect-ip]

环境变量：
  PUBLIC_IP          明确指定公网 IPv4
  HTTPS_PORT         可选；不指定时随机选择 20000-29999 中的空闲端口
  FIREWALL_MODE      主机防火墙处理方式：auto（默认）或 skip
  COUCHDB_USER       CouchDB 用户名，默认 obsidian_user
  COUCHDB_PASSWORD   CouchDB 密码；不指定则随机生成
  COUCHDB_DATABASE   数据库名，默认 obsidiannotes
  VAULT_PASSPHRASE   可选；Self-hosted LiveSync 端到端加密口令
  SETUP_URI_PASSPHRASE  可选；快速导入配置的保护口令
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
    if (( detect_only == 1 )); then
        choose_ip_candidate
        printf '%s\n' "${PUBLIC_IP}"
        return 0
    fi
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 或 sudo 运行。"
    [[ "${COUCHDB_USER}" =~ ^[A-Za-z][A-Za-z0-9_-]{2,31}$ ]] || die "COUCHDB_USER 格式无效。"
    [[ "${COUCHDB_DATABASE}" =~ ^[a-z][a-z0-9_-]{2,63}$ ]] || die "COUCHDB_DATABASE 格式无效。"
    if [[ -n "${COUCHDB_PASSWORD:-}" ]]; then
        [[ "${COUCHDB_PASSWORD}" =~ ^[A-Za-z0-9._~!@%+=:-]{16,128}$ ]] || die "COUCHDB_PASSWORD 需为 16-128 位安全字符。"
    fi
    if [[ -n "${VAULT_PASSPHRASE}" ]]; then
        [[ "${VAULT_PASSPHRASE}" =~ ^[A-Za-z0-9._~!@%+=:-]{20,128}$ ]] || die "VAULT_PASSPHRASE 需为 20-128 位安全字符。"
    fi
    if [[ -n "${SETUP_URI_PASSPHRASE}" ]]; then
        [[ "${SETUP_URI_PASSPHRASE}" =~ ^[A-Za-z0-9._~!@%+=:-]{20,128}$ ]] || die "SETUP_URI_PASSPHRASE 需为 20-128 位安全字符。"
    fi
    detect_system
    install_base_packages
    ensure_docker
    choose_ip_candidate
    select_https_port
    configure_host_firewall

    prepare_files
    compose up -d couchdb couchdb-init
    wait_for_couchdb
    install_acme
    install_renewal_helpers
    issue_certificate
    write_https_caddyfile
    compose --profile https up -d caddy
    compose --profile https exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    write_connection_file
    verify_installation
    "${INSTALL_DIR}/scripts/generate-setup-uri.sh" >/dev/null

    echo
    echo "============================================================"
    echo "  以下信息都很重要，请完整保存，不要公开发送"
    echo "============================================================"
    echo
    cat "${INSTALL_DIR}/connection.txt"
    echo
    cat "${INSTALL_DIR}/setup-uri.txt"
    echo
    echo "以上信息另存于："
    echo "  ${INSTALL_DIR}/connection.txt"
    echo "  ${INSTALL_DIR}/setup-uri.txt"
    echo "  ${INSTALL_DIR}/setup-uri-only.txt（只有完整 URI，可直接全选复制）"
    echo "三个文件权限均为 600。"
    echo "管理命令：${INSTALL_DIR}/manage.sh status"
}

if [[ "${1:-}" != "--source-only" ]]; then
    main "$@"
fi
