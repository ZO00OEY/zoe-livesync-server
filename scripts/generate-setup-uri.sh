#!/usr/bin/env bash
set -euo pipefail

install_dir="${ZOE_INSTALL_DIR:-/opt/zoe-livesync-server}"
env_file="${install_dir}/.env"
output_file="${install_dir}/setup-uri.txt"
deno_image="denoland/deno:alpine-2.9.7"
generator_url="https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/2c2b9c90e4e10a454f2838c63ba656c0e67a374c/utils/setup/generate_setup_uri.ts"

[[ -f "${env_file}" ]] || { echo "未找到 ${env_file}" >&2; exit 1; }

set -a
# shellcheck source=/dev/null
source "${env_file}"
set +a

: "${PUBLIC_URL:?PUBLIC_URL is required}"
: "${COUCHDB_DATABASE:?COUCHDB_DATABASE is required}"
: "${COUCHDB_USER:?COUCHDB_USER is required}"
: "${COUCHDB_PASSWORD:?COUCHDB_PASSWORD is required}"
: "${VAULT_PASSPHRASE:?VAULT_PASSPHRASE is required}"
: "${SETUP_URI_PASSPHRASE:?SETUP_URI_PASSPHRASE is required}"

echo "正在生成 Self-hosted LiveSync 快速导入配置..." >&2
if ! docker image inspect "${deno_image}" >/dev/null 2>&1; then
    docker pull "${deno_image}" >&2
fi
if ! generated="$(docker run --rm \
        -e "hostname=${PUBLIC_URL}" \
        -e "database=${COUCHDB_DATABASE}" \
        -e "username=${COUCHDB_USER}" \
        -e "password=${COUCHDB_PASSWORD}" \
        -e "passphrase=${VAULT_PASSPHRASE}" \
        -e "uri_passphrase=${SETUP_URI_PASSPHRASE}" \
        "${deno_image}" run --minimum-dependency-age=0 --allow-env "${generator_url}")"; then
    echo "快速导入配置生成失败；CouchDB 服务本身不受影响。" >&2
    exit 1
fi

cat > "${output_file}" <<EOF
第二部分：Self-hosted LiveSync 快速导入配置

Vault 端到端加密口令: ${VAULT_PASSPHRASE}
Setup URI 保护口令: ${SETUP_URI_PASSPHRASE}

${generated}

使用方法：在 Obsidian 的 Self-hosted LiveSync 中执行 Open setup URI，粘贴上面的 obsidian://setuplivesync 地址，再输入 Setup URI 保护口令。
安全提示：正式保存时，请把 Setup URI 和它的保护口令分开放置。
EOF
chmod 0600 "${output_file}"
cat "${output_file}"
