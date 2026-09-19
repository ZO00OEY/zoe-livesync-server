#!/usr/bin/env bash
set -euo pipefail

install_dir="${ZOE_INSTALL_DIR:-/opt/zoe-livesync-server}"
env_file="${install_dir}/.env"

if [[ ! -f "${env_file}" ]]; then
    echo "未找到 ${env_file}，请先运行 install.sh。" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "${env_file}"
set +a

compose() {
    local -a profile_args=()
    [[ "${INGRESS_MODE:-standalone}" == "standalone" ]] && profile_args=(--profile standalone)
    if docker compose version >/dev/null 2>&1; then
        docker compose -p zoe-livesync --project-directory "${install_dir}" -f "${install_dir}/compose.yaml" "${profile_args[@]}" "$@"
    else
        docker-compose -p zoe-livesync --project-directory "${install_dir}" -f "${install_dir}/compose.yaml" "${profile_args[@]}" "$@"
    fi
}

case "${1:-status}" in
    status)
        compose ps
        echo
        curl -fsS --user "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${PUBLIC_URL}/_up" && echo
        if [[ "${INGRESS_MODE:-standalone}" == "standalone" ]]; then
            openssl x509 -in "${install_dir}/certs/fullchain.cer" -noout -subject -issuer -dates
        else
            echo "入口由现有 Caddy 管理：${PUBLIC_URL}"
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
        if [[ "${INGRESS_MODE:-standalone}" == "standalone" ]]; then
            /usr/local/sbin/zoe-livesync-renew
        else
            echo "当前证书由现有 Caddy 管理，无需 Zoe 单独续期。"
        fi
        ;;
    config)
        cat "${install_dir}/connection.txt"
        ;;
    *)
        echo "用法: $0 {status|logs [service]|restart|renew|config}" >&2
        exit 2
        ;;
esac
