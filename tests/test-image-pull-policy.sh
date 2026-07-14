#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
DEPLOY_SH="${ROOT_DIR}/deploy.sh"
DEPLOY_PS1="${ROOT_DIR}/deploy.ps1"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"

assert_contains() {
    local file="$1"
    local expected="$2"
    local message="$3"

    if ! grep -Fq -- "$expected" "$file"; then
        printf 'FAIL: %s\nMissing: %s\nFile: %s\n' "$message" "$expected" "$file" >&2
        exit 1
    fi
}

assert_contains "$COMPOSE_FILE" 'image: ${CPA_IMAGE:-eceasy/cli-proxy-api:latest}' 'Compose image must be configurable'
assert_contains "$COMPOSE_FILE" 'pull_policy: ${CPA_PULL_POLICY:-always}' 'Compose must pull on direct starts by default'
assert_contains "$ENV_EXAMPLE" 'CPA_IMAGE=eceasy/cli-proxy-api:latest' 'Image override must be documented'
assert_contains "$ENV_EXAMPLE" 'CPA_PULL_POLICY=always' 'Pull policy must be documented'
assert_contains "$DEPLOY_SH" 'DOCKER_IMAGE="${CPA_IMAGE:-eceasy/cli-proxy-api:latest}"' 'Bash must load the configured image'
assert_contains "$DEPLOY_SH" 'CPA_PULL_POLICY=never' 'Bash recreate must protect transactional rollback'
assert_contains "$DEPLOY_PS1" "'CPA_IMAGE'          { \$script:DOCKER_IMAGE = \$val }" 'PowerShell must load the configured image'
assert_contains "$DEPLOY_PS1" "\$env:CPA_PULL_POLICY = 'never'" 'PowerShell recreate must protect transactional rollback'
assert_contains "$DEPLOY_PS1" '未使用本地缓存冒充最新版本' 'PowerShell pull failure must not silently use stale cache'

printf 'PASS: image pull policy contract is present\n'
