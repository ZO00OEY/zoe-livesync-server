#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${root_dir}/install.sh"
bash -n "${root_dir}/manage.sh"
bash -n "${root_dir}/scripts/generate-setup-uri.sh"

# shellcheck disable=SC1091
source "${root_dir}/install.sh" --source-only

public_cases=("1.1.1.1" "8.8.8.8" "223.5.5.5")
private_cases=(
  "127.0.0.1" "10.0.0.1" "172.16.0.1" "172.31.255.255"
  "192.168.1.1" "100.64.0.1" "169.254.1.1" "192.0.2.10"
  "198.51.100.2" "203.0.113.4" "256.1.1.1" "not-an-ip"
)

for ip in "${public_cases[@]}"; do
    is_public_ipv4 "${ip}" || { echo "Expected public: ${ip}" >&2; exit 1; }
done
for ip in "${private_cases[@]}"; do
    if is_public_ipv4 "${ip}"; then
        echo "Expected non-public: ${ip}" >&2
        exit 1
    fi
done

export INSTALL_DIR="${TMPDIR:-/tmp}/zoe-livesync-self-test-missing"
export PUBLIC_IP="8.8.8.8"
export HTTPS_PORT="8443"
# shellcheck disable=SC2329
port_is_busy() { return 1; }
select_https_port >/dev/null
[[ "${PUBLIC_URL}" == "https://8.8.8.8:8443" ]] || {
    echo "Unexpected public URL: ${PUBLIC_URL}" >&2
    exit 1
}

# A port restored from an earlier automatic install must be replaced when it
# has since been claimed by an unrelated process.
port_test_dir="$(mktemp -d)"
printf '%s\n' 'HTTPS_PORT=24567' > "${port_test_dir}/.env"
INSTALL_DIR="${port_test_dir}"
HTTPS_PORT=""
# shellcheck disable=SC2329
port_is_busy() { [[ "$1" == "24567" ]]; }
docker() { return 1; }
select_https_port >/dev/null 2>&1
[[ "${HTTPS_PORT}" != "24567" && "${HTTPS_PORT}" -ge 20000 && "${HTTPS_PORT}" -le 29999 ]] || {
    echo "Occupied stored port was not replaced: ${HTTPS_PORT}" >&2
    exit 1
}
rm -rf "${port_test_dir}"

export FIREWALL_MODE="skip"
configure_host_firewall >/dev/null 2>&1
[[ "${HOST_FIREWALL_STATUS}" == *"FIREWALL_MODE=skip"* ]] || {
    echo "Unexpected firewall status: ${HOST_FIREWALL_STATUS}" >&2
    exit 1
}

echo "Self-test passed."
