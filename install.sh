#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="Zoe LiveSync Server"
INSTALL_DIR="${ZOE_INSTALL_DIR:-/opt/zoe-livesync-server}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_HOME="${ACME_HOME:-${INSTALL_DIR}/acme}"
ACME_BIN="${ACME_HOME}/acme.sh"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
PUBLIC_IP="${PUBLIC_IP:-}"
COUCHDB_USER="${COUCHDB_USER:-obsidian_user}"
COUCHDB_DATABASE="${COUCHDB_DATABASE:-obsidiannotes}"
HTTPS_PORT="${HTTPS_PORT:-}"
FIREWALL_MODE="${FIREWALL_MODE:-auto}"
TLS_MODE="${TLS_MODE:-auto}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
PORT80_AUTO_RELEASE="${PORT80_AUTO_RELEASE:-0}"
PORT80_OWNER_TYPE="${PORT80_OWNER_TYPE:-}"
PORT80_OWNER_NAME="${PORT80_OWNER_NAME:-}"
PORT80_OWNER_DISPLAY=""
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

stored_public_ip() {
    local value=""
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        value="$(sed -n 's/^PUBLIC_IP=//p' "${INSTALL_DIR}/.env" | head -n 1)"
    fi
    is_public_ipv4 "${value}" && printf '%s\n' "${value}"
}

choose_ip_candidate() {
    local i value answer best_ip="" best_count=0 source_list stored_ip default_ip
    declare -A counts=()
    declare -A sources=()
    local -a unique_ips=()

    if [[ -n "${PUBLIC_IP}" ]]; then
        is_public_ipv4 "${PUBLIC_IP}" || die "PUBLIC_IP=${PUBLIC_IP} 不是可用的公网 IPv4 地址。"
        return
    fi

    stored_ip="$(stored_public_ip || true)"
    collect_ip_candidates
    if ((${#IP_VALUES[@]} == 0)) && [[ -z "${stored_ip}" ]]; then
        die "没有检测到公网 IPv4；可用 PUBLIC_IP=公网IP 指定。"
    fi

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
    if [[ -n "${stored_ip}" ]]; then
        echo "上次确认的公网 IPv4：${stored_ip}"
    fi
    echo "本次检测到的公网 IPv4 候选（局域网、CGNAT、回环及保留地址已过滤）："
    for i in "${!unique_ips[@]}"; do
        value="${unique_ips[$i]}"
        printf '  %d) %s\n     来源：%s\n' "$((i + 1))" "${value}" "${sources["${value}"]}"
    done
    echo
    if ((${#counts[@]} > 1)); then
        warn "不同来源结果不一致，可能存在代理、透明网关或多出口网络。"
    fi
    if [[ -n "${best_ip}" ]]; then
        printf '本次检测建议: %s（%d 个来源一致）\n' "${best_ip}" "${best_count}"
    fi
    if [[ -n "${stored_ip}" ]]; then
        default_ip="${stored_ip}"
        if [[ -n "${best_ip}" && "${stored_ip}" != "${best_ip}" ]]; then
            warn "上次确认值与本次检测建议不一致，请仔细确认。"
        else
            ok "上次确认值与本次检测结果一致。"
        fi
    else
        default_ip="${best_ip}"
    fi

    if [[ "${NON_INTERACTIVE}" == "1" || ! -r /dev/tty ]]; then
        die "非交互模式不会替你确认候选 IP；请重新运行 PUBLIC_IP=${default_ip} NON_INTERACTIVE=1 bash install.sh"
    fi

    if [[ -n "${stored_ip}" ]]; then
        read -r -p "回车继续使用上次确认值 ${stored_ip}，输入候选序号，或输入正确的公网 IPv4: " answer </dev/tty
    else
        read -r -p "回车确认建议值 ${best_ip}，输入候选序号，或输入正确的公网 IPv4: " answer </dev/tty
    fi
    if [[ -z "${answer}" ]]; then
        PUBLIC_IP="${default_ip}"
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

base_tools_ready() {
    local tool
    for tool in curl openssl ip ss socat; do
        command_exists "${tool}" || return 1
    done
    command_exists cron || command_exists crond || return 1
    if command_exists apt-get; then
        command_exists gpg || return 1
    fi
}

install_base_packages() {
    if base_tools_ready; then
        ok "基础工具已完整，跳过系统软件包安装。"
        return
    fi
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
    base_tools_ready || die "基础工具安装后仍不完整。"
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
    local stored_port="" candidate random_value requested_port="${HTTPS_PORT}"
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
                if [[ -n "${requested_port}" ]]; then
                    die "明确指定的 HTTPS 端口 ${HTTPS_PORT} 已被其他服务占用，请换一个端口。"
                fi
                warn "上次自动选择的 HTTPS 端口 ${HTTPS_PORT} 已被其他服务占用，将重新随机选择。"
                HTTPS_PORT=""
            fi
        fi
    fi

    if [[ -z "${HTTPS_PORT}" ]]; then
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

    info "已选定独立随机 HTTPS 端口：${HTTPS_PORT}"
}

valid_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] && [[ "$1" == *.* ]]
}

certificate_matches_key() {
    local cert_hash key_hash
    cert_hash="$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}' || true)"
    key_hash="$(openssl pkey -in "$2" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}' || true)"
    [[ -n "${cert_hash}" && "${cert_hash}" == "${key_hash}" ]]
}

validate_existing_certificate() {
    [[ "${TLS_CERT_FILE}" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || die "TLS_CERT_FILE 必须是无空格的安全绝对路径。"
    [[ "${TLS_KEY_FILE}" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || die "TLS_KEY_FILE 必须是无空格的安全绝对路径。"
    [[ -r "${TLS_CERT_FILE}" ]] || die "证书文件不可读：${TLS_CERT_FILE}"
    [[ -r "${TLS_KEY_FILE}" ]] || die "私钥文件不可读：${TLS_KEY_FILE}"
    valid_hostname "${PUBLIC_HOST}" || die "PUBLIC_HOST 不是有效域名：${PUBLIC_HOST}"
    openssl x509 -checkend 86400 -noout -in "${TLS_CERT_FILE}" >/dev/null 2>&1 || die "现有证书无效或将在 24 小时内过期。"
    openssl x509 -checkhost "${PUBLIC_HOST}" -noout -in "${TLS_CERT_FILE}" >/dev/null 2>&1 || die "现有证书不包含域名 ${PUBLIC_HOST}。"
    certificate_matches_key "${TLS_CERT_FILE}" "${TLS_KEY_FILE}" || die "现有证书与私钥不匹配。"
}

hostname_points_here() {
    getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | grep -Fxq "${PUBLIC_IP}"
}

discover_existing_certificate() {
    local peer_cert peer_hash file file_hash host key root container_id source destination sni_host
    local -a roots=() cert_files=() key_files=()
    peer_cert="$(mktemp)"
    sni_host="$(hostname -f 2>/dev/null || true)"
    if valid_hostname "${sni_host}"; then
        openssl s_client -connect 127.0.0.1:443 -servername "${sni_host}" -showcerts </dev/null 2>/dev/null | \
            awk '/-----BEGIN CERTIFICATE-----/{copy=1} copy{print} /-----END CERTIFICATE-----/{exit}' > "${peer_cert}" || true
    else
        openssl s_client -connect 127.0.0.1:443 -showcerts </dev/null 2>/dev/null | \
            awk '/-----BEGIN CERTIFICATE-----/{copy=1} copy{print} /-----END CERTIFICATE-----/{exit}' > "${peer_cert}" || true
    fi
    if ! openssl x509 -in "${peer_cert}" -noout >/dev/null 2>&1; then
        rm -f "${peer_cert}"
        return 1
    fi
    peer_hash="$(openssl x509 -in "${peer_cert}" -outform DER | sha256sum | awk '{print $1}')"

    for root in /etc/letsencrypt /var/lib/caddy /root/.local/share/caddy /etc/headscale /var/lib/headscale; do
        [[ -d "${root}" ]] && roots+=("${root}")
    done
    while read -r container_id; do
        [[ -n "${container_id}" ]] || continue
        while IFS=$'\t' read -r source destination; do
            case "${destination}" in
                *cert*|*ssl*|*tls*|*/etc/headscale*|*/var/lib/headscale*|/data|/data/*)
                    [[ -e "${source}" ]] && roots+=("${source}")
                    ;;
            esac
        done < <(docker inspect "${container_id}" --format '{{range .Mounts}}{{printf "%s\t%s\n" .Source .Destination}}{{end}}' 2>/dev/null || true)
    done < <(docker ps --filter publish=443 -q 2>/dev/null || true)

    for root in "${roots[@]}"; do
        [[ -d "${root}" ]] || root="$(dirname "${root}")"
        while IFS= read -r -d '' file; do cert_files+=("${file}"); done < <(
            find -L "${root}" -maxdepth 6 -type f \( -name '*.crt' -o -name '*.cer' -o -name '*.pem' \) -print0 2>/dev/null
        )
        while IFS= read -r -d '' file; do key_files+=("${file}"); done < <(
            find -L "${root}" -maxdepth 6 -type f \( -name '*.key' -o -name 'privkey*.pem' -o -name 'key.pem' \) -print0 2>/dev/null
        )
    done

    for file in "${cert_files[@]}"; do
        file_hash="$(openssl x509 -in "${file}" -outform DER 2>/dev/null | sha256sum | awk '{print $1}' || true)"
        [[ "${file_hash}" == "${peer_hash}" ]] || continue
        while read -r host; do
            host="${host#DNS:}"
            [[ "${host}" == \** ]] && continue
            valid_hostname "${host}" || continue
            hostname_points_here "${host}" || continue
            curl --noproxy '*' --resolve "${host}:443:127.0.0.1" -sS --connect-timeout 5 --max-time 10 \
                -o /dev/null "https://${host}/" 2>/dev/null || continue
            for key in "${key_files[@]}"; do
                if certificate_matches_key "${file}" "${key}"; then
                    PUBLIC_HOST="${host}"
                    TLS_CERT_FILE="${file}"
                    TLS_KEY_FILE="${key}"
                    rm -f "${peer_cert}"
                    return 0
                fi
            done
        done < <(openssl x509 -in "${file}" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' || true)
    done
    rm -f "${peer_cert}"
    return 1
}

detect_port80_owner() {
    local pid unit image
    local -a containers=() units=()
    mapfile -t containers < <(docker ps --filter publish=80 --format '{{.Names}}' 2>/dev/null | sort -u)
    if ((${#containers[@]} == 1)); then
        PORT80_OWNER_TYPE="docker"
        PORT80_OWNER_NAME="${containers[0]}"
        image="$(docker inspect "${PORT80_OWNER_NAME}" --format '{{.Config.Image}}' 2>/dev/null || true)"
        PORT80_OWNER_DISPLAY="Docker 容器 ${PORT80_OWNER_NAME}${image:+（${image}）}"
        return 0
    fi
    while read -r pid; do
        unit="$(sed -n 's|.*/\([^/]*\.service\)$|\1|p' "/proc/${pid}/cgroup" 2>/dev/null | head -n 1)"
        [[ -n "${unit}" ]] && units+=("${unit}")
    done < <(ss -H -ltnp 'sport = :80' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    if ((${#units[@]} > 0)); then
        mapfile -t units < <(printf '%s\n' "${units[@]}" | sort -u)
    fi
    if ((${#units[@]} == 1)) && systemctl is-active --quiet "${units[0]}"; then
        PORT80_OWNER_TYPE="systemd"
        PORT80_OWNER_NAME="${units[0]}"
        PORT80_OWNER_DISPLAY="systemd 服务 ${PORT80_OWNER_NAME}"
        return 0
    fi
    PORT80_OWNER_DISPLAY="$(ss -H -ltnp 'sport = :80' 2>/dev/null | head -n 1)"
    return 1
}

confirm_port80_release() {
    local answer
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        [[ "${PORT80_AUTO_RELEASE}" == "1" && -n "${PORT80_OWNER_TYPE}" && -n "${PORT80_OWNER_NAME}" ]] || \
            die "非交互模式不会停止 80 端口服务；需预先明确 PORT80_AUTO_RELEASE=1、PORT80_OWNER_TYPE 和 PORT80_OWNER_NAME。"
        return
    fi
    printf '%b[危险]%b 当前 80 端口被 %s 占用，是否强制关闭？\n' "${red}" "${reset}" "${PORT80_OWNER_DISPLAY}" >&2
    printf '脚本只会在证书验证期间临时停止，并在成功、失败或中断后自动恢复。输入 YES 继续：'
    read -r answer
    [[ "${answer}" == "YES" ]] || die "已取消安装，未停止任何现有服务。"
    PORT80_AUTO_RELEASE=1
}

select_tls_mode() {
    local answer stored_mode="" stored_host="" stored_cert="" stored_key=""
    local stored_release="" stored_owner_type="" stored_owner_name=""
    local expected_owner_type="" expected_owner_name=""
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        stored_mode="$(sed -n 's/^TLS_MODE=//p' "${INSTALL_DIR}/.env" | head -n 1)"
        stored_host="$(sed -n 's/^PUBLIC_HOST=//p' "${INSTALL_DIR}/.env" | head -n 1)"
        stored_cert="$(sed -n 's/^TLS_CERT_FILE=//p' "${INSTALL_DIR}/.env" | head -n 1)"
        stored_key="$(sed -n 's/^TLS_KEY_FILE=//p' "${INSTALL_DIR}/.env" | head -n 1)"
        stored_release="$(sed -n 's/^PORT80_AUTO_RELEASE=//p' "${INSTALL_DIR}/.env" | head -n 1)"
        stored_owner_type="$(sed -n 's/^PORT80_OWNER_TYPE=//p' "${INSTALL_DIR}/.env" | head -n 1)"
        stored_owner_name="$(sed -n 's/^PORT80_OWNER_NAME=//p' "${INSTALL_DIR}/.env" | head -n 1)"
    fi
    if [[ -z "${PORT80_OWNER_TYPE}" && "${stored_release}" == "1" ]]; then
        PORT80_AUTO_RELEASE="${stored_release}"
        PORT80_OWNER_TYPE="${stored_owner_type}"
        PORT80_OWNER_NAME="${stored_owner_name}"
    fi
    if [[ "${TLS_MODE}" == "auto" && "${stored_mode}" == "existing" && -n "${stored_host}" ]]; then
        TLS_MODE="existing"; PUBLIC_HOST="${stored_host}"; TLS_CERT_FILE="${stored_cert}"; TLS_KEY_FILE="${stored_key}"
    fi
    if [[ -n "${TLS_CERT_FILE}" || -n "${TLS_KEY_FILE}" || -n "${PUBLIC_HOST}" ]]; then
        [[ -n "${TLS_CERT_FILE}" && -n "${TLS_KEY_FILE}" && -n "${PUBLIC_HOST}" ]] || \
            die "复用证书时必须同时提供 PUBLIC_HOST、TLS_CERT_FILE 和 TLS_KEY_FILE。"
        TLS_MODE="existing"
    fi

    case "${TLS_MODE}" in
        existing)
            validate_existing_certificate
            ;;
        ip)
            PUBLIC_HOST="${PUBLIC_IP}"
            ;;
        auto)
            if port_is_busy 443 && discover_existing_certificate; then
                info "检测到当前 HTTPS 证书：${PUBLIC_HOST}"
                info "证书文件：${TLS_CERT_FILE}"
                if [[ "${NON_INTERACTIVE}" == "1" ]]; then
                    die "非交互模式不会自动复用现有私钥；请明确传入 PUBLIC_HOST、TLS_CERT_FILE、TLS_KEY_FILE。"
                fi
                printf '1. 复用该证书（推荐，不停止现有服务）\n2. 不复用并退出\n请选择 [1]: '
                read -r answer
                [[ -z "${answer}" || "${answer}" == "1" ]] || die "已取消安装，未修改现有服务。"
                TLS_MODE="existing"
                validate_existing_certificate
            elif port_is_busy 80; then
                expected_owner_type="${PORT80_OWNER_TYPE}"
                expected_owner_name="${PORT80_OWNER_NAME}"
                if detect_port80_owner; then
                    if [[ "${PORT80_AUTO_RELEASE}" == "1" && -n "${expected_owner_type}" ]] && \
                       [[ "${expected_owner_type}:${expected_owner_name}" != "${PORT80_OWNER_TYPE}:${PORT80_OWNER_NAME}" ]]; then
                        if [[ "${NON_INTERACTIVE}" == "1" ]]; then
                            die "80 端口占用者已从 ${expected_owner_type}:${expected_owner_name} 变为 ${PORT80_OWNER_TYPE}:${PORT80_OWNER_NAME}，拒绝使用旧授权。"
                        fi
                        warn "80 端口占用者与上次授权对象不同，将重新征求确认。"
                        PORT80_AUTO_RELEASE=0
                    fi
                    confirm_port80_release
                    TLS_MODE="ip"
                    PUBLIC_HOST="${PUBLIC_IP}"
                else
                    printf '%b[危险]%b 当前 80 端口被以下进程占用：%s\n' "${red}" "${reset}" "${PORT80_OWNER_DISPLAY}" >&2
                    die "无法确认它属于可自动恢复的 Docker 容器或 systemd 服务，因此拒绝直接结束进程。"
                fi
            else
                TLS_MODE="ip"
                PUBLIC_HOST="${PUBLIC_IP}"
            fi
            ;;
        *) die "TLS_MODE 只能是 auto、ip 或 existing。" ;;
    esac

    if [[ "${HTTPS_PORT}" == "443" ]]; then
        PUBLIC_URL="https://${PUBLIC_HOST}"
    else
        PUBLIC_URL="https://${PUBLIC_HOST}:${HTTPS_PORT}"
    fi
    ok "HTTPS 模式：$([[ "${TLS_MODE}" == "existing" ]] && printf '复用现有域名证书' || printf '公网 IP 证书')；访问地址 ${PUBLIC_URL}"
}

check_local_service_ports() {
    if port_is_busy 5984 && ! docker port zoe-livesync-couchdb 5984/tcp 2>/dev/null | grep -Eq '127\.0\.0\.1:5984$'; then
        ss -H -ltnp 'sport = :5984' 2>/dev/null >&2 || true
        die "本机 127.0.0.1:5984 已被其他服务占用；为避免接管现有 CouchDB，安装已停止。"
    fi
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
    local port zone route_interface
    local -a required_ports=("${HTTPS_PORT}")
    [[ "${TLS_MODE}" == "ip" ]] && required_ports=(80 "${HTTPS_PORT}")

    case "${FIREWALL_MODE}" in
        auto) ;;
        skip)
            HOST_FIREWALL_STATUS="已按 FIREWALL_MODE=skip 跳过自动配置"
            warn "已跳过主机防火墙配置；请自行确认 TCP ${required_ports[*]} 可入站。"
            return
            ;;
        *) die "FIREWALL_MODE 只能是 auto 或 skip。" ;;
    esac

    if command_exists ufw && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        for port in "${required_ports[@]}"; do
            ufw allow "${port}/tcp" >/dev/null || die "UFW 放行 TCP ${port} 失败。"
        done
        HOST_FIREWALL_STATUS="UFW 已自动放行 TCP ${required_ports[*]}"
        ok "${HOST_FIREWALL_STATUS}。"
        return
    fi

    if command_exists firewall-cmd && firewall-cmd --state 2>/dev/null | grep -qx 'running'; then
        route_interface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
        if [[ -n "${route_interface}" ]]; then
            zone="$(firewall-cmd --get-zone-of-interface="${route_interface}" 2>/dev/null || true)"
            [[ "${zone}" == "no zone" ]] && zone=""
        fi
        [[ -n "${zone}" ]] || zone="$(firewall-cmd --get-default-zone 2>/dev/null || true)"
        [[ -n "${zone}" ]] || die "无法确定公网默认路由所属的 firewalld zone，请使用 FIREWALL_MODE=skip 后手动放行。"
        firewall-cmd --get-zones 2>/dev/null | tr ' ' '\n' | grep -Fxq "${zone}" || die "firewalld zone ${zone} 不存在。"
        for port in "${required_ports[@]}"; do
            firewall-cmd --zone="${zone}" --add-port="${port}/tcp" >/dev/null || die "firewalld 临时放行 TCP ${port} 失败。"
            firewall-cmd --permanent --zone="${zone}" --add-port="${port}/tcp" >/dev/null || die "firewalld 永久放行 TCP ${port} 失败。"
        done
        HOST_FIREWALL_STATUS="firewalld 区域 ${zone}${route_interface:+（公网路由接口 ${route_interface}）} 已自动放行 TCP ${required_ports[*]}"
        ok "${HOST_FIREWALL_STATUS}。"
        return
    fi

    if custom_firewall_is_restrictive; then
        HOST_FIREWALL_STATUS="检测到自定义 nftables/iptables 入站限制，未自动修改"
        warn "${HOST_FIREWALL_STATUS}；请手动放行 TCP ${required_ports[*]}。"
    else
        HOST_FIREWALL_STATUS="未检测到启用中的 UFW/firewalld；未新增主机防火墙规则"
        info "${HOST_FIREWALL_STATUS}。"
    fi
}

prepare_files() {
    mkdir -p "${INSTALL_DIR}"/{config,scripts,certs}
    install -m 0644 "${SOURCE_DIR}/compose.yaml" "${INSTALL_DIR}/compose.yaml"
    install -m 0644 "${SOURCE_DIR}/config/livesync.ini" "${INSTALL_DIR}/config/livesync.ini"
    install -m 0644 "${SOURCE_DIR}/scripts/provision-couchdb.ts" "${INSTALL_DIR}/scripts/provision-couchdb.ts"
    install -m 0755 "${SOURCE_DIR}/scripts/generate-setup-uri.sh" "${INSTALL_DIR}/scripts/generate-setup-uri.sh"
    install -m 0755 "${SOURCE_DIR}/scripts/with-port80-released.sh" "${INSTALL_DIR}/scripts/with-port80-released.sh"
    install -m 0644 "${SOURCE_DIR}/scripts/create-setup-uri.ts" "${INSTALL_DIR}/scripts/create-setup-uri.ts"
    install -m 0755 "${SOURCE_DIR}/manage.sh" "${INSTALL_DIR}/manage.sh"

    local password="${COUCHDB_PASSWORD:-}" confirmed_ip="${PUBLIC_IP}" confirmed_url="${PUBLIC_URL}" confirmed_port="${HTTPS_PORT}"
    local confirmed_tls_mode="${TLS_MODE}" confirmed_host="${PUBLIC_HOST}" confirmed_cert="${TLS_CERT_FILE}" confirmed_key="${TLS_KEY_FILE}"
    local confirmed_release="${PORT80_AUTO_RELEASE}" confirmed_owner_type="${PORT80_OWNER_TYPE}" confirmed_owner_name="${PORT80_OWNER_NAME}"
    local requested_vault_passphrase="${VAULT_PASSPHRASE}" requested_uri_passphrase="${SETUP_URI_PASSPHRASE}"
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        # shellcheck source=/dev/null
        source "${INSTALL_DIR}/.env"
        password="${COUCHDB_PASSWORD}"
    fi
    PUBLIC_IP="${confirmed_ip}"
    PUBLIC_URL="${confirmed_url}"
    HTTPS_PORT="${confirmed_port}"
    TLS_MODE="${confirmed_tls_mode}"
    PUBLIC_HOST="${confirmed_host}"
    TLS_CERT_FILE="${confirmed_cert}"
    TLS_KEY_FILE="${confirmed_key}"
    PORT80_AUTO_RELEASE="${confirmed_release}"
    PORT80_OWNER_TYPE="${confirmed_owner_type}"
    PORT80_OWNER_NAME="${confirmed_owner_name}"
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
TLS_MODE=${TLS_MODE}
PUBLIC_HOST=${PUBLIC_HOST}
TLS_CERT_FILE=${TLS_CERT_FILE}
TLS_KEY_FILE=${TLS_KEY_FILE}
PORT80_AUTO_RELEASE=${PORT80_AUTO_RELEASE}
PORT80_OWNER_TYPE=${PORT80_OWNER_TYPE}
PORT80_OWNER_NAME=${PORT80_OWNER_NAME}
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

https://${PUBLIC_HOST} {
    tls /certs/fullchain.cer /certs/tls.key
    reverse_proxy couchdb:5984 {
        flush_interval -1
    }
}
EOF
}

install_acme() {
    if [[ -x "${ACME_BIN}" ]]; then
        if "${ACME_BIN}" --help 2>&1 | grep -q -- '--certificate-profile'; then
            ok "本项目隔离的 acme.sh 已安装。"
            return
        fi
        warn "现有项目内 acme.sh 不支持证书 profile，将更新项目副本。"
    fi
    info "安装本项目隔离的 acme.sh（不修改服务器已有的 acme.sh 任务）。"
    local installer
    installer="$(mktemp)"
    curl -fsSL https://get.acme.sh -o "${installer}" || { rm -f "${installer}"; die "下载 acme.sh 安装器失败。"; }
    local -a install_args=(--install --home "${ACME_HOME}" --config-home "${ACME_HOME}" --nocron --noprofile)
    if [[ -n "${ACME_EMAIL:-}" ]]; then
        install_args+=(--accountemail "${ACME_EMAIL}")
    fi
    sh "${installer}" "${install_args[@]}" >/dev/null || { rm -f "${installer}"; die "acme.sh 安装失败。"; }
    rm -f "${installer}"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 安装失败。"
    "${ACME_BIN}" --help 2>&1 | grep -q -- '--certificate-profile' || die "acme.sh 版本不支持 IP 短期证书 profile。"
}

run_with_port80_available() {
    if port_is_busy 80; then
        env PORT80_AUTO_RELEASE="${PORT80_AUTO_RELEASE}" PORT80_OWNER_TYPE="${PORT80_OWNER_TYPE}" \
            PORT80_OWNER_NAME="${PORT80_OWNER_NAME}" \
            "${INSTALL_DIR}/scripts/with-port80-released.sh" -- "$@"
    else
        "$@"
    fi
}

issue_certificate() {
    local cert_file="${INSTALL_DIR}/certs/fullchain.cer"
    local key_file="${INSTALL_DIR}/certs/tls.key"

    if [[ -f "${cert_file}" ]] && openssl x509 -checkend 86400 -noout -in "${cert_file}" >/dev/null 2>&1 && \
       openssl x509 -in "${cert_file}" -noout -text | grep -Fq "IP Address:${PUBLIC_IP}"; then
        ok "现有 IP 证书仍有效，跳过首次签发。"
    else
        info "向 Let's Encrypt 申请短期公网 IP 证书。"
        run_with_port80_available "${ACME_BIN}" --issue --home "${ACME_HOME}" --server letsencrypt -d "${PUBLIC_IP}" \
            --certificate-profile shortlived --days -1 --standalone --listen-v4 --ecc --force
    fi
    "${ACME_BIN}" --install-cert --home "${ACME_HOME}" -d "${PUBLIC_IP}" --ecc \
        --fullchain-file "${cert_file}" --key-file "${key_file}" \
        --reloadcmd "${INSTALL_DIR}/manage.sh reload-caddy"

    openssl x509 -checkend 86400 -noout -in "${cert_file}" >/dev/null 2>&1 || die "签发结果不是有效证书。"
    openssl x509 -in "${cert_file}" -noout -text | grep -Fq "IP Address:${PUBLIC_IP}" || die "证书 SAN 与公网 IP 不匹配。"
    chmod 0644 "${cert_file}"
    chmod 0600 "${key_file}"
}

install_existing_certificate() {
    validate_existing_certificate
    install -m 0644 "${TLS_CERT_FILE}" "${INSTALL_DIR}/certs/fullchain.cer"
    install -m 0600 "${TLS_KEY_FILE}" "${INSTALL_DIR}/certs/tls.key"
    ok "已复制并验证 ${PUBLIC_HOST} 的现有证书；原服务仍负责续签。"
}

prepare_tls_certificate() {
    if [[ "${TLS_MODE}" == "existing" ]]; then
        install_existing_certificate
    else
        install_acme
        issue_certificate
    fi
}

install_renewal_schedule() {
    cat > /etc/cron.d/zoe-livesync-renew <<EOF
17 */12 * * * root "${INSTALL_DIR}/manage.sh" renew >> /var/log/zoe-livesync-renew.log 2>&1
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

provision_couchdb() {
    info "配置 CouchDB，并初始化 LiveSync 数据库版本。"
    if ! compose run --rm --no-deps couchdb-init; then
        compose logs --tail=150 couchdb >&2 || true
        die "CouchDB 初始化失败；未继续签发证书或显示成功信息。"
    fi
    ok "CouchDB 初始化和 LiveSync 数据库版本验证通过。"
}

verify_couchdb_configuration() {
    local base="http://127.0.0.1:5984" body setting
    body="$(curl -fsS --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${base}/${COUCHDB_DATABASE}")" || \
        die "CouchDB 数据库 ${COUCHDB_DATABASE} 不存在或无法读取。"
    grep -Fq '"db_name":"'"${COUCHDB_DATABASE}"'"' <<< "${body}" || die "CouchDB 数据库响应不正确。"
    setting="$(curl -fsS --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
        "${base}/_node/_local/_config/chttpd/require_valid_user")" || die "无法读取 CouchDB 认证配置。"
    [[ "${setting}" == '"true"' ]] || die "CouchDB require_valid_user 未正确启用。"
    setting="$(curl -fsS --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
        "${base}/_node/_local/_config/cors/origins")" || die "无法读取 CouchDB CORS 配置。"
    grep -Fq 'app://obsidian.md' <<< "${setting}" || die "CouchDB CORS 配置缺少 Obsidian 来源。"
    ok "数据库存在，认证和 CORS 配置验证通过。"
}

write_connection_file() {
    local firewall_note port_note certificate_note
    if [[ "${TLS_MODE}" == "existing" ]]; then
        firewall_note="请确认 TCP ${HTTPS_PORT} 已放行。"
        port_note="TCP ${HTTPS_PORT} 用于 LiveSync HTTPS 连接；现有服务继续占用自己的 80/443。"
        certificate_note="复用 ${PUBLIC_HOST} 的现有证书；原服务负责续签，Zoe 定时同步并重载自己的 Caddy。"
    else
        firewall_note="请确认 TCP 80 和 TCP ${HTTPS_PORT} 已放行。"
        port_note="TCP 80 用于首次签发及自动续期 IP 证书；TCP ${HTTPS_PORT} 用于 LiveSync HTTPS 连接。"
        certificate_note="由 Zoe 管理 Let's Encrypt 公网 IP 短期证书。"
        if [[ "${PORT80_AUTO_RELEASE}" == "1" ]]; then
            certificate_note+=" 验证时临时停止并自动恢复 ${PORT80_OWNER_TYPE}:${PORT80_OWNER_NAME}。"
        fi
    fi
    cat > "${INSTALL_DIR}/connection.txt" <<EOF
第一部分：CouchDB API 连接信息

API 类型: CouchDB
API URL: ${PUBLIC_URL}
HTTPS 端口: ${HTTPS_PORT}
认证方式: HTTP Basic Auth（没有单独的 API Key）
用户名: ${COUCHDB_USER}
密码: ${COUCHDB_PASSWORD}
数据库: ${COUCHDB_DATABASE}
证书方式: ${certificate_note}

主机防火墙: ${HOST_FIREWALL_STATUS}
云安全组: 通用服务器脚本无法修改，${firewall_note}
端口说明: ${port_note}

注意：首次设备请使用一个单独保存的端到端加密口令；它不是上面的 CouchDB 密码。
EOF
    chmod 0600 "${INSTALL_DIR}/connection.txt"
}

verify_installation() {
    compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
    local body
    body="$(curl --noproxy '*' -fsS --connect-timeout 5 --max-time 15 \
        --resolve "${PUBLIC_HOST}:${HTTPS_PORT}:127.0.0.1" \
        --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${PUBLIC_URL}/_up")" || die "本机 HTTPS、证书或 Caddy 验证失败。"
    grep -q '"status":"ok"' <<< "${body}" || die "HTTPS 已响应，但 CouchDB 健康检查内容不正确。"
    ok "本机 HTTPS、证书、Caddy 与 CouchDB 端到端验证通过。"

    if curl --noproxy '*' -fsS --connect-timeout 5 --max-time 15 \
        --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${PUBLIC_URL}/_up" 2>/dev/null | grep -q '"status":"ok"'; then
        ok "服务器经公网地址回环访问验证通过。"
    else
        warn "服务器无法经自己的公网地址回环访问；这不一定代表外部不可用，请从手机网络访问 ${PUBLIC_URL}/_up 验证云安全组。"
    fi
}

usage() {
    cat <<'EOF'
用法：sudo bash install.sh [--non-interactive] [--detect-ip]

环境变量：
  PUBLIC_IP          明确指定公网 IPv4
  HTTPS_PORT         可选；不指定时随机选择 20000-29999 中的空闲端口
  TLS_MODE           auto（默认）、ip 或 existing
  PUBLIC_HOST        复用证书时使用的域名
  TLS_CERT_FILE      复用证书时的完整证书链绝对路径
  TLS_KEY_FILE       复用证书时的私钥绝对路径
  PORT80_AUTO_RELEASE 设为 1 时，允许证书验证期间临时停止已确认的 80 端口服务
  PORT80_OWNER_TYPE  非交互模式明确指定 docker 或 systemd
  PORT80_OWNER_NAME  非交互模式明确指定容器名或 systemd 单元名
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
    [[ "${PORT80_AUTO_RELEASE}" == "0" || "${PORT80_AUTO_RELEASE}" == "1" ]] || die "PORT80_AUTO_RELEASE 只能是 0 或 1。"
    [[ -z "${PORT80_OWNER_TYPE}" || "${PORT80_OWNER_TYPE}" == "docker" || "${PORT80_OWNER_TYPE}" == "systemd" ]] || die "PORT80_OWNER_TYPE 只能是 docker 或 systemd。"
    [[ -z "${PORT80_OWNER_NAME}" || "${PORT80_OWNER_NAME}" =~ ^[A-Za-z0-9_.@:-]+$ ]] || die "PORT80_OWNER_NAME 格式无效。"
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
    select_tls_mode
    check_local_service_ports
    configure_host_firewall

    prepare_files
    compose up -d couchdb
    wait_for_couchdb
    provision_couchdb
    verify_couchdb_configuration
    prepare_tls_certificate
    install_renewal_schedule
    write_https_caddyfile
    compose up -d caddy
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
