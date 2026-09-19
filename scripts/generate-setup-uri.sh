#!/usr/bin/env bash
set -euo pipefail

install_dir="${ZOE_INSTALL_DIR:-/opt/zoe-livesync-server}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${install_dir}/.env"
output_file="${install_dir}/setup-uri.txt"
uri_only_file="${install_dir}/setup-uri-only.txt"
deno_image="denoland/deno:alpine-2.9.7"

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
if ! setup_uri="$(docker run --rm \
        -v "${script_dir}/create-setup-uri.ts:/app/create-setup-uri.ts:ro" \
        -e "hostname=${PUBLIC_URL}" \
        -e "database=${COUCHDB_DATABASE}" \
        -e "username=${COUCHDB_USER}" \
        -e "password=${COUCHDB_PASSWORD}" \
        -e "passphrase=${VAULT_PASSPHRASE}" \
        -e "uri_passphrase=${SETUP_URI_PASSPHRASE}" \
        "${deno_image}" run --minimum-dependency-age=0 --allow-env /app/create-setup-uri.ts)"; then
    echo "快速导入配置生成失败；CouchDB 服务本身不受影响。" >&2
    exit 1
fi

[[ "${setup_uri}" == obsidian://setuplivesync\?settings=* ]] || { echo "Setup URI 前缀无效。" >&2; exit 1; }
[[ ! "${setup_uri}" =~ [[:space:]] ]] || { echo "Setup URI 中出现了意外空白字符。" >&2; exit 1; }

printf '%s\n' "${setup_uri}" > "${uri_only_file}"

cat > "${output_file}" <<EOF
第二部分：Self-hosted LiveSync 快速导入配置

======================================================================
一、Setup URI 中已经包含的基础配置
======================================================================

1. CouchDB 地址（数据库服务器地址）
   当前值: ${PUBLIC_URL}
   意义: Self-hosted LiveSync 通过这个 HTTPS 地址连接服务器上的 CouchDB。

2. 数据库名
   当前值: ${COUCHDB_DATABASE}
   意义: 当前 Vault 的同步数据存放在 CouchDB 的这个数据库中。

3. 用户
   当前值: ${COUCHDB_USER}
   意义: Self-hosted LiveSync 连接 CouchDB 时使用的认证用户名。

4. 密码
   当前值: ${COUCHDB_PASSWORD}
   意义: 上述 CouchDB 用户的认证密码；它已加密写入 Setup URI，请勿公开 URI。

5. Vault 端到端加密口令
   当前值: ${VAULT_PASSPHRASE}
   意义: 用于加密同步到 CouchDB 的笔记内容和路径信息；它与 CouchDB 密码不同。

6. 同步启动
   当前值: 开启（syncOnStart=true）
   意义: 每次启动 Obsidian 时，自动执行一次文件同步。

7. 同步周期
   当前值: 开启，每 60 秒一次（periodicReplication=true）
   意义: Obsidian 打开期间，按 Self-hosted LiveSync 上游默认间隔定期检查并交换变更。

8. 复制与触发方式
   周期双向复制: 开启
   持续实时连接 LiveSync: 关闭（liveSync=false）
   打开文件时同步: 开启（syncOnFileOpen=true）
   合并文件后同步: 开启（syncAfterMerge=true）
   批量写入本地数据库: 开启（batchSave=true）
   意义: 本地与 CouchDB 双向交换变更，同时减少频繁磁盘写入；这不是一直保持的实时连接模式。

9. 远程类型
   当前值: CouchDB（已设为活动远程配置）
   意义: 插件会使用 CouchDB 同步模块，而不是 S3 对象存储或 P2P 模式。

======================================================================
二、不在 Setup URI 里面、但导入时必须输入的信息
======================================================================

Setup URI 保护口令: ${SETUP_URI_PASSPHRASE}
意义: 只用于解密下面这条 Setup URI；它不包含在 URI 自身之中，也不同于 Vault 加密口令。

======================================================================
====================== 只复制下一行完整内容 =========================
======================================================================

${setup_uri}

======================================================================
====================== 完整复制到上一行结束 =========================
======================================================================

使用方法：在 Obsidian 的 Self-hosted LiveSync 中执行 Open setup URI，粘贴上面完整的一行，再输入 Setup URI 保护口令。
纯 URI 文件：${uri_only_file}（文件中只有一行，可直接全选复制）
说明：终端窗口较窄时 URI 可能在屏幕上视觉换行，但文件内仍然只有一个逻辑行。
安全提示：正式保存时，请把 Setup URI 和它的保护口令分开放置。
EOF
chmod 0600 "${output_file}" "${uri_only_file}"
cat "${output_file}"
