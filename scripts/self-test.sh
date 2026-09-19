#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${root_dir}/install.sh"
bash -n "${root_dir}/manage.sh"
sh -n "${root_dir}/scripts/couchdb-init.sh"
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
port_is_busy() { return 1; }
select_https_port >/dev/null
[[ "${PUBLIC_URL}" == "https://8.8.8.8:8443" ]] || {
    echo "Unexpected public URL: ${PUBLIC_URL}" >&2
    exit 1
}

echo "Self-test passed."
