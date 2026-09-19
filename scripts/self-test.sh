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

( # shellcheck disable=SC2329
  command_exists() { return 0; }; base_tools_ready ) || {
    echo "Complete base tools should be accepted" >&2
    exit 1
}
if ( # shellcheck disable=SC2329
     command_exists() { [[ "$1" != "socat" ]]; }; base_tools_ready ); then
    echo "Missing base tool should be rejected" >&2
    exit 1
fi

export INSTALL_DIR="${TMPDIR:-/tmp}/zoe-livesync-self-test-missing"
export PUBLIC_IP="8.8.8.8"
export HTTPS_PORT="8443"
# shellcheck disable=SC2329
port_is_busy() { return 1; }
select_https_port >/dev/null
TLS_MODE="auto"
select_tls_mode >/dev/null
[[ "${PUBLIC_URL}" == "https://8.8.8.8:8443" ]] || {
    echo "Unexpected public URL: ${PUBLIC_URL}" >&2
    exit 1
}

# A port restored from an earlier automatic install must be replaced when it
# has since been claimed by an unrelated process.
port_test_dir="$(mktemp -d)"
printf '%s\n' 'HTTPS_PORT=24567' > "${port_test_dir}/.env"
printf '%s\n' 'PUBLIC_IP=8.8.4.4' >> "${port_test_dir}/.env"
INSTALL_DIR="${port_test_dir}"
[[ "$(stored_public_ip)" == "8.8.4.4" ]] || {
    echo "Stored public IP was not loaded" >&2
    exit 1
}
HTTPS_PORT=""
# shellcheck disable=SC2329
port_is_busy() { [[ "$1" == "24567" ]]; }
# shellcheck disable=SC2329
docker() { return 1; }
select_https_port >/dev/null 2>&1
[[ "${HTTPS_PORT}" != "24567" && "${HTTPS_PORT}" -ge 20000 && "${HTTPS_PORT}" -le 29999 ]] || {
    echo "Occupied stored port was not replaced: ${HTTPS_PORT}" >&2
    exit 1
}
rm -rf "${port_test_dir}"

stored_mode_dir="$(mktemp -d)"
cat > "${stored_mode_dir}/.env" <<'EOF'
TLS_MODE=ip
PUBLIC_HOST=8.8.8.8
TLS_CERT_FILE=
TLS_KEY_FILE=
EOF
INSTALL_DIR="${stored_mode_dir}"
PUBLIC_IP="8.8.8.8"
HTTPS_PORT="24443"
TLS_MODE="auto"
PUBLIC_HOST=""
TLS_CERT_FILE=""
TLS_KEY_FILE=""
# A rerun keeps its confirmed IP-certificate mode even if port 80 is now busy.
# shellcheck disable=SC2329
port_is_busy() { [[ "$1" == "80" ]]; }
select_tls_mode >/dev/null
[[ "${TLS_MODE}" == "ip" && "${PUBLIC_HOST}" == "8.8.8.8" ]] || {
    echo "Stored IP certificate mode was not restored" >&2
    exit 1
}
rm -rf "${stored_mode_dir}"

export FIREWALL_MODE="skip"
configure_host_firewall >/dev/null 2>&1
[[ "${HOST_FIREWALL_STATUS}" == *"FIREWALL_MODE=skip"* ]] || {
    echo "Unexpected firewall status: ${HOST_FIREWALL_STATUS}" >&2
    exit 1
}

cert_test_dir="$(mktemp -d)"
cert_subject='/CN=sync.example.com'
[[ "${OSTYPE:-}" == msys* ]] && cert_subject='//CN=sync.example.com'
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj "${cert_subject}" \
    -keyout "${cert_test_dir}/source.key" -out "${cert_test_dir}/source.pem" >/dev/null 2>&1
INSTALL_DIR="${cert_test_dir}/install"
export PUBLIC_HOST="sync.example.com"
export TLS_CERT_FILE="${cert_test_dir}/source.pem"
export TLS_KEY_FILE="${cert_test_dir}/source.key"
export TLS_MODE="existing"
mkdir -p "${INSTALL_DIR}/config" "${INSTALL_DIR}/certs"
# shellcheck disable=SC2329
hostname_points_here() { return 0; }
validate_existing_certificate
install_existing_certificate >/dev/null
write_https_caddyfile
grep -Fq 'https://sync.example.com' "${INSTALL_DIR}/config/Caddyfile"
grep -Fq 'tls /certs/fullchain.cer /certs/tls.key' "${INSTALL_DIR}/config/Caddyfile"
certificate_matches_key "${INSTALL_DIR}/certs/fullchain.cer" "${INSTALL_DIR}/certs/tls.key"
rm -rf "${cert_test_dir}"

ip_cert_dir="$(mktemp -d)"
cat > "${ip_cert_dir}/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = 8.8.8.8
[ext]
subjectAltName = IP:8.8.8.8
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -config "${ip_cert_dir}/openssl.cnf" \
    -keyout "${ip_cert_dir}/source.key" -out "${ip_cert_dir}/source.pem" >/dev/null 2>&1
export PUBLIC_IP="8.8.8.8"
export PUBLIC_HOST="8.8.8.8"
export TLS_CERT_FILE="${ip_cert_dir}/source.pem"
export TLS_KEY_FILE="${ip_cert_dir}/source.key"
validate_existing_certificate
certificate_covers_public_host "${TLS_CERT_FILE}"
rm -rf "${ip_cert_dir}"

echo "Self-test passed."
