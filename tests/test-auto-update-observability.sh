#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="${ROOT_DIR}/deploy.sh"

assert_contains() {
    local expected="$1"
    local message="$2"

    if ! grep -Fq -- "$expected" "${DEPLOY_SCRIPT}"; then
        printf 'FAIL: %s\nMissing: %s\n' "$message" "$expected" >&2
        exit 1
    fi
}

assert_contains 'CPA_UPDATE_TRIGGER=cron' 'managed cron command must identify itself as cron'
assert_contains '触发来源:' 'auto-update log must show the trigger source'
assert_contains '服务器时间:' 'auto-update log must show server time'
assert_contains '北京时间:' 'auto-update log must show Beijing time'
assert_contains '服务器时区:' 'status must show the server time zone'
assert_contains '最近 cron 触发:' 'status must show the latest cron journal record'

printf 'PASS: auto-update observability contract is present\n'
