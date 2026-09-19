#!/usr/bin/env bash
set -euo pipefail

owner_type="${PORT80_OWNER_TYPE:-}"
owner_name="${PORT80_OWNER_NAME:-}"

fail() { printf '[错误] %s\n' "$*" >&2; exit 1; }
port_busy() { ss -H -ltnp 'sport = :80' 2>/dev/null | grep -q .; }

docker_owns_port() {
    docker ps --filter publish=80 --format '{{.Names}}' 2>/dev/null | grep -Fxq "${owner_name}"
}

systemd_owns_port() {
    local pid unit
    systemctl is-active --quiet "${owner_name}" || return 1
    while read -r pid; do
        unit="$(sed -n 's|.*/\([^/]*\.service\)$|\1|p' "/proc/${pid}/cgroup" 2>/dev/null | head -n 1)"
        [[ "${unit}" == "${owner_name}" ]] && return 0
    done < <(ss -H -ltnp 'sport = :80' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    return 1
}

owner_still_matches() {
    case "${owner_type}" in
        docker) docker_owns_port ;;
        systemd) systemd_owns_port ;;
        *) return 1 ;;
    esac
}

stop_owner() {
    case "${owner_type}" in
        docker) docker stop -t 30 "${owner_name}" >/dev/null ;;
        systemd) systemctl stop "${owner_name}" ;;
    esac
}

start_owner() {
    case "${owner_type}" in
        docker) docker start "${owner_name}" >/dev/null ;;
        systemd) systemctl start "${owner_name}" ;;
    esac
}

[[ "${1:-}" == "--" && $# -ge 2 ]] || fail "内部调用格式错误。"
shift
[[ "${PORT80_AUTO_RELEASE:-0}" == "1" ]] || fail "没有获得临时停止 80 端口服务的授权。"
[[ "${owner_type}" == "docker" || "${owner_type}" == "systemd" ]] || fail "80 端口占用者类型无效。"
[[ "${owner_name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*$ ]] || fail "80 端口占用者名称无效。"
owner_still_matches || {
    ss -H -ltnp 'sport = :80' 2>/dev/null >&2 || true
    fail "当前 80 端口占用者与已确认的 ${owner_type}:${owner_name} 不一致，拒绝停止。"
}

restore_owner() {
    local status="$1"
    trap - EXIT
    if ! start_owner; then
        printf '[错误] 未能自动恢复 %s:%s，请立即手动检查。\n' "${owner_type}" "${owner_name}" >&2
        exit 1
    fi
    exit "${status}"
}
trap 'restore_owner "$?"' EXIT
trap 'exit 130' HUP INT TERM

printf '[信息] 临时停止 %s:%s，释放 80 端口。\n' "${owner_type}" "${owner_name}"
stop_owner
for _ in {1..30}; do
    port_busy || break
    sleep 1
done
port_busy && fail "停止 ${owner_name} 后 80 端口仍被占用。"

"$@"
