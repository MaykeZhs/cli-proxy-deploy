#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/bin:/bin:${PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SH="${ROOT_DIR}/deploy.sh"
DEPLOY_PS1="${ROOT_DIR}/deploy.ps1"
README_FILE="${ROOT_DIR}/README.md"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local text="$1" expected="$2" message="$3"
    grep -Fq -- "$expected" <<< "${text}" || fail "${message}; missing ${expected}"
}

assert_not_contains() {
    local text="$1" forbidden="$2" message="$3"
    if grep -Fq -- "$forbidden" <<< "${text}"; then
        fail "${message}; found protected value ${forbidden}"
    fi
}

grep -Fq 'CAP_SCHEMA_VERSION=1' "${DEPLOY_SH}" || fail 'Bash schema version must remain 1'
grep -Fq 'schema_version = 1' "${DEPLOY_PS1}" || fail 'PowerShell schema version must remain 1'
grep -Fq 'The JSON contract uses `schema_version: 1`.' "${README_FILE}" || fail 'README schema version is missing'
grep -Fq 'probe_cpa_capabilities' "${DEPLOY_SH}" || fail 'Bash Doctor must reuse the shared probe'
grep -Fq '$probe = Get-CpaCapabilityProbe' "${DEPLOY_PS1}" || fail 'PowerShell Doctor must reuse the shared probe'
grep -Fq 'capability_is_audited_v72102' "${DEPLOY_SH}" || fail 'The preserved v7.2.102 audit contract is missing'
grep -Fq 'capability_is_audited_v72111' "${DEPLOY_SH}" || fail 'The exact v7.2.111 audit contract is missing'

if awk '/^cmd_doctor\(\)/,/^cmd_backup\(\)/' "${DEPLOY_SH}" | grep -Eq 'docker (run|pull|start|stop|restart|create)|compose .* (up|down|pull|restart|create)'; then
    fail 'Bash Doctor v2 contains a mutating Docker command'
fi
if awk '/^function cmd-doctor/,/^function cmd-backup/' "${DEPLOY_PS1}" | grep -Eq 'docker (run|pull|start|stop|restart|create)|compose .* (up|down|pull|restart|create)'; then
    fail 'PowerShell Doctor v2 contains a mutating Docker command'
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
MOCK_BIN="${TMP_DIR}/mock-bin"
MOCK_DOCKER_LOG="${TMP_DIR}/docker.log"
MOCK_HTTP_LOG="${TMP_DIR}/http.log"
MOCK_FALLBACK_MARKER="${TMP_DIR}/fallback-used"
mkdir -p "${MOCK_BIN}" "${TMP_DIR}/backups"
cp "${DEPLOY_SH}" "${TMP_DIR}/deploy.sh"
cp "${ROOT_DIR}/docker-compose.yml" "${TMP_DIR}/docker-compose.yml"

cat > "${TMP_DIR}/config.yaml" <<'EOF'
api-keys:
  - "sk-test-secret-never-print"
remote-management:
  allow-remote: true
  secret-key: "management-hash-never-print"
  disable-control-panel: false
plugins:
  enabled: true
routing:
  strategy: weighted-round-robin
  session-affinity: true
  session-affinity-ttl: "45m"
EOF
touch "${TMP_DIR}/backups/cli-proxy-manager-backup-20260727-120000.tgz"

cat > "${MOCK_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf '%q ' "$@"
    printf '\n'
} >> "${MOCK_DOCKER_LOG}"
case "${1:-}" in
    info) exit 0 ;;
    compose)
        [[ "${2:-}" == "version" ]] && exit 0
        [[ "$*" == *' config --quiet' ]] && exit 0
        ;;
    inspect)
        printf '%s\n' 'eceasy/cli-proxy-api:latest|sha256:live-image-id|true'
        exit 0
        ;;
    port)
        printf '%s\n' '0.0.0.0:8317'
        exit 0
        ;;
    image)
        [[ "$*" == *'{{range .RepoDigests}}'* ]] && printf '%s\n' 'eceasy/cli-proxy-api@sha256:repository-digest'
        exit 0
        ;;
    logs)
        printf '%s\n' 'CLIProxyAPI Version: v7.2.111, Commit: 4a31513, BuildDate: test'
        exit 0
        ;;
    exec)
        if [[ "$*" == *'ldd /proc/1/exe'* ]]; then
            printf 'true'
        else
            : > "${MOCK_FALLBACK_MARKER}"
            printf '%s\n' 'antigravity=1' 'claude=1' 'codex=1' 'gemini=1' 'kimi=1' 'xai=1' 'all=8'
        fi
        exit 0
        ;;
esac
exit 1
EOF
chmod +x "${MOCK_BIN}/docker"

cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
for argument in "$@"; do
    [[ "${argument}" == http://* || "${argument}" == https://* ]] && url="${argument}"
done
printf '%s\n' "${url}" >> "${MOCK_HTTP_LOG}"
has_auth=false
has_dump_headers=false
previous=""
for argument in "$@"; do
    [[ "${argument}" == "-D" ]] && has_dump_headers=true
    if [[ "${previous}" == "-H" && "${argument}" == Authorization:\ Bearer\ * ]]; then
        has_auth=true
    fi
    previous="${argument}"
done
case "${url}" in
    */healthz) printf '200' ;;
    */management.html)
        printf '%s\n__CPA_STATUS__:200' '<html>footer.version tileValue children:`v1.20.4` private-center-content</html>'
        ;;
    */v1/models) printf '%s\n200' '{"data":[{"id":"model-private-never-print"}]}' ;;
    */v0/management/config)
        ${has_auth} || exit 9
        if ${has_dump_headers}; then
            printf 'HTTP/1.1 200 OK\r\nX-CPA-VERSION: v7.2.111\r\nX-CPA-COMMIT: 4a31513\r\nX-CPA-SUPPORT-PLUGIN: 1\r\n\r\n\n__CPA_STATUS__:200'
        else
            printf '%s\n__CPA_STATUS__:200' '{"routing":{"strategy":"weighted-round-robin","session-affinity":true,"session-affinity-ttl":"45m"},"codex-api-key":[{"api-key":"config-secret-never-print","priority":9,"weight":913579}],"openai-compatibility":[{"name":"private-provider","priority":7,"api-key-entries":[{"api-key":"compat-secret-never-print","weight":765431}]}]}'
        fi
        ;;
    */v0/management/auth-files)
        ${has_auth} || exit 9
        printf '%s\n__CPA_STATUS__:200' '{"files":[{"type":"antigravity","status":"ready","priority":1,"weight":246813,"name":"ag-private.json","email":"ag@example.test"},{"type":"claude","status":"ready","priority":2,"account_id":"account-private"},{"type":"codex","status":"ready","priority":3,"model_id":"model-private"},{"type":"gemini-cli","status":"ready","priority":4},{"type":"kimi","status":"ready","priority":5},{"type":"x-ai","status":"ready","priority":6},{"type":"futurecloud","status":"ready","priority":7},{"type":"leak@example.test","status":"ready","priority":8}]}'
        ;;
    */v0/management/plugins)
        ${has_auth} || exit 9
        printf '%s\n__CPA_STATUS__:200' '{"plugins_enabled":true,"plugins":[{"id":"safe-plugin","configured":true,"enabled":true,"effective_enabled":true,"menus":[{},{}],"metadata":{"name":"Safe Plugin","version":"1.2.3","author":"private@example.test","config_fields":{"token":"plugin-secret-never-print"}},"path":"/private/plugin/path","external_credential":"external-secret-never-print"}]}'
        ;;
    */v0/management/routing/strategy)
        ${has_auth} || exit 9
        printf '%s\n__CPA_STATUS__:200' '{"strategy":"weighted-round-robin"}'
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${MOCK_BIN}/curl"

cat > "${TMP_DIR}/.env" <<'EOF'
CPA_BIND_HOST=0.0.0.0
CPA_PORT=8317
CPA_IMAGE=eceasy/cli-proxy-api:latest
CPA_MANAGEMENT_KEY=management-plaintext-never-print
EOF

AUTH_OUTPUT="$(PATH="${MOCK_BIN}:${PATH}" MOCK_DOCKER_LOG="${MOCK_DOCKER_LOG}" MOCK_HTTP_LOG="${MOCK_HTTP_LOG}" MOCK_FALLBACK_MARKER="${MOCK_FALLBACK_MARKER}" bash "${TMP_DIR}/deploy.sh" capabilities --json)"
printf '%s' "${AUTH_OUTPUT}" | python -m json.tool >/dev/null || fail 'Bash authenticated JSON is invalid'

for expected in \
    '"schema_version": 1' \
    '"exposure_mode": "direct-public"' \
    '"version": "v7.2.111"' \
    '"commit": "4a315136730baa8b3a436d12b74e5a702c70be5c"' \
    '"cpa_version": "v7.2.111"' \
    '"management_center_version": "v1.20.4"' \
    '"management_center_commit": "826ea3c0d0bdd6409a0a2703ada90faaf5aede2d"' \
    '"source": "exact_release_tags"' \
    '"target_pair_compatible": true' \
    '"compatibility_status": "compatible"' \
    '"enabled": true' \
    '"reachable": true' \
    '"http_status": 200' \
    '"local_url": "http://127.0.0.1:8317/management.html"' \
    '"version_source": "management_html"' \
    '"external_https_protection": null' \
    '"public_access_warning": "critical"' \
    '"contract_source": "live_and_audited"' \
    '"management_api_available": true' \
    '"priority_write_supported": true' \
    '"quota_reset_supported": true' \
    '"strategy": "weighted-round-robin"' \
    '"weighted_round_robin_supported": true' \
    '"weighted_round_robin_configured": true' \
    '"priority_supported": true' \
    '"priority_configured": true' \
    '"credential_weights_configured": true' \
    '"session_affinity_supported": true' \
    '"session_affinity_enabled": true' \
    '"session_affinity_ttl": "45m"' \
    '"automatic_failover_supported": true' \
    '"wrr_traffic_validation": "not_run"' \
    '"plugin_system_supported": true' \
    '"plugin_system_configured": true' \
    '"plugin_system_enabled": true' \
    '"inspection": "available"' \
    '"id": "safe-plugin"' \
    '"name": "Safe Plugin"' \
    '"version": "1.2.3"' \
    '"menu_count": 2' \
    '"plugin_resource_pages_management_authenticated": false' \
    '"critical_public_plugin_resource_exposure": true' \
    '"source": "management_api"' \
    '"kimi": 1' \
    '"xai": 1' \
    '"unknown": 1' \
    '"type": "futurecloud"' \
    '"total": 8' \
    '"code": "PUBLIC_PLUGIN_RESOURCES_UNAUTHENTICATED"'; do
    assert_contains "${AUTH_OUTPUT}" "${expected}" 'Bash authenticated capability output is incomplete'
done

for forbidden in \
    'management-plaintext-never-print' 'management-hash-never-print' 'sk-test-secret-never-print' \
    'ag-private.json' 'ag@example.test' 'private@example.test' 'account-private' 'model-private' \
    '/private/plugin/path' 'plugin-secret-never-print' 'external-secret-never-print' \
    'config-secret-never-print' 'compat-secret-never-print' 'private-provider' \
    '913579' '765431' '246813'; do
    assert_not_contains "${AUTH_OUTPUT}" "${forbidden}" 'Bash output exposed protected data'
done
[[ ! -e "${MOCK_FALLBACK_MARKER}" ]] || fail 'Filename fallback ran even though auth-files API succeeded'

cat > "${TMP_DIR}/.env" <<'EOF'
CPA_BIND_HOST=0.0.0.0
CPA_PORT=8317
CPA_IMAGE=eceasy/cli-proxy-api:latest
EOF
: > "${MOCK_HTTP_LOG}"
rm -f "${MOCK_FALLBACK_MARKER}"
NO_KEY_OUTPUT="$(PATH="${MOCK_BIN}:${PATH}" MOCK_DOCKER_LOG="${MOCK_DOCKER_LOG}" MOCK_HTTP_LOG="${MOCK_HTTP_LOG}" MOCK_FALLBACK_MARKER="${MOCK_FALLBACK_MARKER}" bash "${TMP_DIR}/deploy.sh" capabilities --json)"
printf '%s' "${NO_KEY_OUTPUT}" | python -m json.tool >/dev/null || fail 'Bash missing-key JSON is invalid'
if grep -Fq '/v0/management/' "${MOCK_HTTP_LOG}"; then
    fail 'Bash called a protected Management API endpoint without a plaintext key'
fi
assert_contains "${NO_KEY_OUTPUT}" '"reason": "management_key_unavailable"' 'Missing-key plugin reason is wrong'
assert_contains "${NO_KEY_OUTPUT}" '"source": "filename_fallback"' 'Missing-key provider fallback source is missing'
assert_contains "${NO_KEY_OUTPUT}" '"unknown": 2' 'Filename fallback unknown-provider count is wrong'
assert_contains "${NO_KEY_OUTPUT}" '"priority_configured": null' 'Missing-key priority state must be unknown'
assert_contains "${NO_KEY_OUTPUT}" '"credential_weights_configured": null' 'Missing-key weight state must be unknown'
assert_contains "${NO_KEY_OUTPUT}" '"wrr_traffic_validation": "not_run"' 'Missing-key WRR validation state is wrong'
[[ -e "${MOCK_FALLBACK_MARKER}" ]] || fail 'Filename fallback did not run without a management key'

while IFS= read -r call || [[ -n "${call}" ]]; do
    call="${call% }"
    case "${call}" in
        info|compose\ version|compose\ *\ config\ --quiet|inspect\ --format\ *|port\ *|image\ inspect\ *|logs\ --tail\ *|exec\ *) ;;
        *) fail "Unexpected Docker call from read-only probe: ${call}" ;;
    esac
done < "${MOCK_DOCKER_LOG}"

printf 'PASS: Bash D2.2 release contract is exact, read-only, redacted, and no-key safe\n'
