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

case "${1:-status}" in
    status)
        compose ps
        echo
        curl --noproxy '*' -fsS --resolve "${PUBLIC_IP}:${HTTPS_PORT}:127.0.0.1" \
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
        "${acme_home}/acme.sh" --cron --home "${acme_home}"
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
