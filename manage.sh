#!/usr/bin/env bash
set -euo pipefail

install_dir="${ZOE_INSTALL_DIR:-/opt/zoe-livesync-server}"
env_file="${install_dir}/.env"

if [[ ! -f "${env_file}" ]]; then
    echo "未找到 ${env_file}，请先运行 install.sh。" >&2
    exit 1
fi

set -a
source "${env_file}"
set +a

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose --project-directory "${install_dir}" -f "${install_dir}/compose.yaml" "$@"
    else
        docker-compose --project-directory "${install_dir}" -f "${install_dir}/compose.yaml" "$@"
    fi
}

case "${1:-status}" in
    status)
        compose ps
        echo
        curl -fsS --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "https://${PUBLIC_IP}/_up" && echo
        openssl x509 -in "${install_dir}/certs/fullchain.cer" -noout -subject -issuer -dates
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
        /usr/local/sbin/zoe-livesync-renew
        ;;
    config)
        cat "${install_dir}/connection.txt"
        ;;
    *)
        echo "用法: $0 {status|logs [service]|restart|renew|config}" >&2
        exit 2
        ;;
esac
