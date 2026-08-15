#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly ENV_FILE="${SCRIPT_DIR}/poc.env"
readonly ENV_EXAMPLE="${SCRIPT_DIR}/poc.env.example"
readonly METADATA_FILE="${SCRIPT_DIR}/poc-metadata.json"
readonly PROJECT_NAME="cursor-bridge-poc"
readonly CONTAINER_NAME="cursor-bridge-poc"
readonly SOURCE_REPOSITORY="https://github.com/anyrobert/cursor-api-proxy"
readonly SOURCE_COMMIT="c0ff1f941215027c0a8f658ca5d01f806559208f"
readonly IMAGE_TAG="cursor-api-proxy:poc-c0ff1f941215027c0a8f658ca5d01f806559208f"

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$1"; }

env_value() {
    local key="$1"
    awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit }' "$ENV_FILE"
}

require_env() {
    [[ -f "$ENV_FILE" ]] || fail "run: bash poc.sh init"
    local cursor_key bridge_key
    cursor_key="$(env_value CURSOR_API_KEY)"
    bridge_key="$(env_value CURSOR_BRIDGE_API_KEY)"
    [[ -n "$cursor_key" && "$cursor_key" != replace-locally-* ]] || fail 'CURSOR_API_KEY is not configured'
    [[ "$bridge_key" =~ ^[A-Fa-f0-9]{64}$ ]] || fail 'CURSOR_BRIDGE_API_KEY must be 64 hex characters'
    [[ "$cursor_key" != "$bridge_key" ]] || fail 'Cursor and bridge keys must be different'
}

compose() {
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
}

docker_readonly() {
    case "${1:-}" in
        port|logs|inspect) ;;
        *) fail 'doctor may only use the port, logs, or inspect verbs' ;;
    esac
    docker "$@"
}

curl_auth() {
    local bridge_key="$1"
    shift
    printf 'header = "Authorization: Bearer %s"\n' "$bridge_key" |
      curl --config - "$@"
}

cmd_init() {
    [[ ! -e "$ENV_FILE" ]] || fail 'poc.env already exists'
    command -v openssl >/dev/null || fail 'openssl is required'
    local tmp bridge_key
    tmp="$(umask 077; mktemp "${ENV_FILE}.tmp.XXXXXX")"
    bridge_key="$(openssl rand -hex 32)"
    sed "s/replace-locally-with-random-64-hex-key/${bridge_key}/" "$ENV_EXAMPLE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    info 'Created poc.env. Edit CURSOR_API_KEY locally before build/start.'
}

cmd_build() {
    require_env
    docker buildx build --load \
      --label "org.opencontainers.image.source=${SOURCE_REPOSITORY}" \
      --label "org.opencontainers.image.revision=${SOURCE_COMMIT}" \
      -t "$IMAGE_TAG" \
      "${SOURCE_REPOSITORY}.git#${SOURCE_COMMIT}"
    local image_id
    image_id="$(docker image inspect "$IMAGE_TAG" --format '{{.Id}}')"
    printf '{"source_commit":"%s","image":"%s","image_id":"%s"}\n' \
      "$SOURCE_COMMIT" "$IMAGE_TAG" "$image_id" > "$METADATA_FILE"
    chmod 600 "$METADATA_FILE" 2>/dev/null || true
    info "Built and recorded ${IMAGE_TAG}"
}

cmd_start() { require_env; compose config --quiet; compose up -d; }
cmd_stop() { require_env; compose stop; }
cmd_destroy() {
    compose down --remove-orphans
}
cmd_logs() { require_env; compose logs --tail 200 cursor-bridge; }
cmd_status() {
    require_env
    compose ps
    docker inspect "$CONTAINER_NAME" --format \
      'User={{.Config.User}} Image={{.Image}} Restart={{.RestartCount}} OOM={{.State.OOMKilled}} Ports={{json .HostConfig.PortBindings}}'
}

cmd_doctor() {
    require_env
    command -v curl >/dev/null || fail 'curl is required'
    command -v jq >/dev/null || fail 'jq is required'
    local port bridge_key cursor_key base unauth models logs
    port="$(env_value CURSOR_BRIDGE_POC_PORT)"; port="${port:-18765}"
    bridge_key="$(env_value CURSOR_BRIDGE_API_KEY)"
    cursor_key="$(env_value CURSOR_API_KEY)"
    base="http://127.0.0.1:${port}"
    [[ "$(docker_readonly port "$CONTAINER_NAME" 8765/tcp)" == "127.0.0.1:${port}" ]] || fail 'bridge is not loopback-only'
    [[ "$(curl -fsS "$base/healthz")" == ok ]] || fail 'liveness failed'
    unauth="$(curl -sS -o /dev/null -w '%{http_code}' "$base/v1/models")"
    [[ "$unauth" == 401 ]] || fail "unauthenticated models returned ${unauth}"
    health_json="$(curl_auth "$bridge_key" -fsS "$base/health")"
    jq -e '.ok == true and .mode == "ask" and .force == false and .approveMcps == false' >/dev/null <<JQ
${health_json}
JQ
    models="$(curl_auth "$bridge_key" -fsS --max-time 70 "$base/v1/models")"
    jq -e '.object == "list" and (.data | length) > 0' >/dev/null <<JQ
${models}
JQ
    logs="$(docker_readonly logs "$CONTAINER_NAME" 2>&1 || true)"
    [[ "$logs" != *"$bridge_key"* && "$logs" != *"$cursor_key"* ]] || fail 'a credential appears in logs'
    inspect_json="$(docker_readonly inspect "$CONTAINER_NAME")"
    jq -e '.[0].Config.User == "app" and (.[0].HostConfig.Memory | tonumber) == 2147483648 and (.[0].HostConfig.PidsLimit | tonumber) == 128 and (.[0].HostConfig.SecurityOpt | index("no-new-privileges:true")) and (.[0].HostConfig.CapDrop | index("ALL"))' >/dev/null <<JQ
${inspect_json}
JQ
    info 'Doctor PASS'
}

cmd_smoke() {
    require_env
    command -v jq >/dev/null || fail 'jq is required'
    local port bridge_key base models model
    port="$(env_value CURSOR_BRIDGE_POC_PORT)"; port="${port:-18765}"
    bridge_key="$(env_value CURSOR_BRIDGE_API_KEY)"
    base="http://127.0.0.1:${port}"
    models="$(curl_auth "$bridge_key" -fsS --max-time 70 "$base/v1/models")"
    model="$(jq -r '.data[0].id' <<JQ
${models}
JQ
)"
    sync_json="$(curl_auth "$bridge_key" -fsS --max-time 180 \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply with exactly CURSOR_POC_OK"}],stream:false}')" \
      "$base/v1/chat/completions")"
    jq -e '.choices[0].message.content | contains("CURSOR_POC_OK")' >/dev/null <<JQ
${sync_json}
JQ
    stream_out="$(curl_auth "$bridge_key" -sSN --max-time 180 \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply with exactly STREAM_OK"}],stream:true}')" \
      "$base/v1/chat/completions")"
    [[ "$stream_out" == *data:* ]] || fail 'streaming smoke failed'
    info 'Smoke PASS'
}

case "${1:-help}" in
    init) cmd_init ;;
    build) cmd_build ;;
    start) cmd_start ;;
    status) cmd_status ;;
    doctor) cmd_doctor ;;
    smoke) cmd_smoke ;;
    logs) cmd_logs ;;
    stop) cmd_stop ;;
    destroy) cmd_destroy ;;
    help|--help|-h) printf '%s\n' 'Usage: bash poc.sh init|build|start|status|doctor|smoke|logs|stop|destroy' ;;
    *) fail "unknown command: $1" ;;
esac
