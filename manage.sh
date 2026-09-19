#!/usr/bin/env bash
set -euo pipefail

install_dir="${ZOE_INSTALL_DIR:-/opt/zoe-livesync-server}"
env_file="${install_dir}/.env"
acme_home="${ACME_HOME:-${install_dir}/acme}"
failure_file="${install_dir}/certificate-renewal-failed.txt"

if [[ ! -f "${env_file}" ]]; then
    echo "未找到 ${env_file}，请先运行 install.sh。" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "${env_file}"
set +a

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose -p zoe-livesync --project-directory "${install_dir}" -f "${install_dir}/compose.yaml" "$@"
    else
        docker-compose -p zoe-livesync --project-directory "${install_dir}" -f "${install_dir}/compose.yaml" "$@"
    fi
}

certificate_matches_key() {
    local cert_hash key_hash
    cert_hash="$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}' || true)"
    key_hash="$(openssl pkey -in "$2" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}' || true)"
    [[ -n "${cert_hash}" && "${cert_hash}" == "${key_hash}" ]]
}

certificate_covers_host() {
    if [[ "${PUBLIC_HOST}" == "${PUBLIC_IP}" ]]; then
        openssl x509 -checkip "${PUBLIC_HOST}" -noout -in "$1" >/dev/null
    else
        openssl x509 -checkhost "${PUBLIC_HOST}" -noout -in "$1" >/dev/null
    fi
}

sync_existing_certificate() {
    local staging
    [[ -r "${TLS_CERT_FILE}" && -r "${TLS_KEY_FILE}" ]]
    openssl x509 -checkend 86400 -noout -in "${TLS_CERT_FILE}"
    certificate_covers_host "${TLS_CERT_FILE}"
    certificate_matches_key "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
    staging="$(mktemp -d "${install_dir}/certs/.incoming.XXXXXX")"
    if ! install -m 0644 "${TLS_CERT_FILE}" "${staging}/fullchain.cer" || \
       ! install -m 0600 "${TLS_KEY_FILE}" "${staging}/tls.key" || \
       ! openssl x509 -checkend 86400 -noout -in "${staging}/fullchain.cer" >/dev/null || \
       ! certificate_covers_host "${staging}/fullchain.cer" || \
       ! certificate_matches_key "${staging}/fullchain.cer" "${staging}/tls.key"; then
        rm -rf "${staging}"
        echo "复制现有证书时源文件发生变化或副本校验失败；未替换本项目证书。" >&2
        return 1
    fi
    if ! cmp -s "${staging}/fullchain.cer" "${install_dir}/certs/fullchain.cer" || \
       ! cmp -s "${staging}/tls.key" "${install_dir}/certs/tls.key"; then
        install -m 0644 "${staging}/fullchain.cer" "${install_dir}/certs/fullchain.cer"
        install -m 0600 "${staging}/tls.key" "${install_dir}/certs/tls.key"
        rm -rf "${staging}"
        "$0" reload-caddy
    else
        rm -rf "${staging}"
    fi
}

renew_ip_certificate() {
    if openssl x509 -checkend 86400 -noout -in "${install_dir}/certs/fullchain.cer"; then
        return
    fi
    if ss -H -ltnp 'sport = :80' 2>/dev/null | grep -q .; then
        echo "公网 IP 证书需要续签，但 TCP 80 当前被其他服务占用；未停止该服务。" >&2
        return 1
    else
        "${acme_home}/acme.sh" --cron --home "${acme_home}"
    fi
}

case "${1:-status}" in
    status)
        compose ps
        echo
        curl --noproxy '*' -fsS --resolve "${PUBLIC_HOST:-${PUBLIC_IP}}:${HTTPS_PORT}:127.0.0.1" \
            --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${PUBLIC_URL}/_up" && echo
        curl -fsS --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
            "http://127.0.0.1:5984/${COUCHDB_DATABASE}" >/dev/null
        openssl x509 -in "${install_dir}/certs/fullchain.cer" -noout -subject -issuer -dates
        if [[ -f "${install_dir}/certificate-renewal-failed.txt" ]]; then
            echo
            echo "警告：最近一次证书续期失败：" >&2
            cat "${install_dir}/certificate-renewal-failed.txt" >&2
            exit 1
        fi
        ;;
    logs)
        if [[ -n "${2:-}" ]]; then
            compose logs --tail=200 "$2"
        else
            compose logs --tail=200
        fi
        ;;
    restart)
        compose restart
        ;;
    renew)
        trap 'printf "续期失败时间: %s\n请重试: %s renew\n" "$(date -Is)" "$0" > "${failure_file}"' ERR
        if [[ "${TLS_MODE:-ip}" == "existing" ]]; then
            sync_existing_certificate
        else
            renew_ip_certificate
        fi
        openssl x509 -checkend 86400 -noout -in "${install_dir}/certs/fullchain.cer"
        rm -f "${failure_file}"
        ;;
    reload-caddy)
        if docker ps --format '{{.Names}}' | grep -qx zoe-livesync-caddy; then
            compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
        fi
        ;;
    config)
        cat "${install_dir}/connection.txt"
        echo
        cat "${install_dir}/setup-uri.txt"
        ;;
    setup-uri)
        "${install_dir}/scripts/generate-setup-uri.sh"
        ;;
    uri)
        cat "${install_dir}/setup-uri-only.txt"
        ;;
    *)
        echo "用法: $0 {status|logs [service]|restart|renew|config|setup-uri|uri}" >&2
        exit 2
        ;;
esac
