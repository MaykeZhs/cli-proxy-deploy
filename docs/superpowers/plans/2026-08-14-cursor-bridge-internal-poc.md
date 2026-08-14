# Cursor Bridge Internal POC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a disposable, loopback-only Stage A harness that validates the pinned Cursor Bridge without touching live CPA, Nginx, Sub2API, CPAMP, or production credentials.

**Architecture:** A self-contained `poc/cursor-bridge/` directory builds upstream commit `c0ff1f941215027c0a8f658ca5d01f806559208f`, runs one hardened container on `127.0.0.1:18765`, and supplies matching Bash and PowerShell lifecycle/Doctor commands. Stage A ends after bridge-only evidence; CPA integration is a separate future plan.

**Tech Stack:** Bash, PowerShell 7, Docker Buildx, Docker Compose v2, curl, jq or PowerShell JSON parsing, static contract tests.

---

## File structure

Create:

- `poc/cursor-bridge/docker-compose.yml` — disposable bridge-only Compose stack.
- `poc/cursor-bridge/poc.env.example` — safe non-secret defaults and local secret placeholders.
- `poc/cursor-bridge/poc.sh` — Linux/macOS lifecycle, validation, Doctor, and smoke commands.
- `poc/cursor-bridge/poc.ps1` — matching PowerShell 7 lifecycle, validation, Doctor, and smoke commands.
- `poc/cursor-bridge/README.md` — operator guide, scope, acceptance record, and STOP conditions.
- `tests/test-cursor-bridge-poc-contract.sh` — static Bash contract and isolation checks.
- `tests/test-cursor-bridge-poc-contract.ps1` — matching PowerShell contract checks.

Modify:

- `.gitignore` — ignore POC secrets and generated metadata.
- `SECURITY.md` — document the POC threat boundary.
- `README.md` — add one experimental POC link without rewriting existing dirty content.

Do not modify:

- `deploy.sh`, `deploy.ps1`, `docker-compose.yml`, `config.yaml`,
  `config.example.yaml`, `.env`, `.env.example`;
- `docker-compose.sub2api.yml`, `sub2api.env.example`, `cpa-manager-plus/**`;
- `install.sh`, `install.ps1`, Nginx/aaPanel files;
- existing untracked `AGENTS.md` and image/video integration documents.

### Task 1: Add the failing static contract tests

**Files:**

- Create: `tests/test-cursor-bridge-poc-contract.sh`
- Create: `tests/test-cursor-bridge-poc-contract.ps1`

- [ ] **Step 1: Write the Bash contract test**

Create a test that fails until all POC files and required controls exist:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POC_DIR="${ROOT_DIR}/poc/cursor-bridge"
COMPOSE_FILE="${POC_DIR}/docker-compose.yml"
ENV_EXAMPLE="${POC_DIR}/poc.env.example"
BASH_SCRIPT="${POC_DIR}/poc.sh"
PS_SCRIPT="${POC_DIR}/poc.ps1"
SOURCE_COMMIT="c0ff1f941215027c0a8f658ca5d01f806559208f"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
not_contains() { ! grep -Fq -- "$2" "$1" || fail "$3"; }

for file in "$COMPOSE_FILE" "$ENV_EXAMPLE" "$BASH_SCRIPT" "$PS_SCRIPT"; do
    [[ -f "$file" ]] || fail "missing $file"
done

contains "$BASH_SCRIPT" "$SOURCE_COMMIT" 'Bash source commit is not pinned'
contains "$PS_SCRIPT" "$SOURCE_COMMIT" 'PowerShell source commit is not pinned'
contains "$COMPOSE_FILE" '127.0.0.1:${CURSOR_BRIDGE_POC_PORT:-18765}:8765' 'POC bind is not loopback-only'
not_contains "$COMPOSE_FILE" '0.0.0.0:${CURSOR_BRIDGE_POC_PORT' 'POC publishes a public host port'
contains "$COMPOSE_FILE" 'pull_policy: never' 'POC image must not pull mutable remote content at start'
not_contains "$COMPOSE_FILE" 'latest' 'POC Compose must not use a latest tag'
not_contains "$ENV_EXAMPLE" 'latest' 'POC env example must not use a latest tag'
contains "$COMPOSE_FILE" 'cap_drop:' 'capability drop is missing'
contains "$COMPOSE_FILE" '      - ALL' 'ALL capabilities are not dropped'
contains "$COMPOSE_FILE" 'no-new-privileges:true' 'no-new-privileges is missing'
contains "$COMPOSE_FILE" 'pids_limit: 128' 'PID limit is missing'
contains "$COMPOSE_FILE" 'mem_limit: 2g' 'memory limit is missing'
contains "$COMPOSE_FILE" 'cpus: "2.0"' 'CPU limit is missing'
not_contains "$COMPOSE_FILE" '/var/run/docker.sock' 'Docker socket must not be mounted'
not_contains "$COMPOSE_FILE" '/root/.cli-proxy-api' 'CPA auth volume must not be mounted'
not_contains "$COMPOSE_FILE" '../config.yaml' 'live CPA config must not be mounted'

for required in \
    'CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true' \
    'CURSOR_BRIDGE_MODE=ask' \
    'CURSOR_BRIDGE_FORCE=false' \
    'CURSOR_BRIDGE_APPROVE_MCPS=false' \
    'CURSOR_BRIDGE_VERBOSE=false' \
    'CURSOR_BRIDGE_MAX_MODE=false' \
    'CURSOR_BRIDGE_USE_ACP=true' \
    'CURSOR_BRIDGE_ACP_RAW_DEBUG=false' \
    'CURSOR_BRIDGE_MULTI_PORT=false'; do
    contains "$ENV_EXAMPLE" "$required" "missing safe setting $required"
done

not_contains "$ENV_EXAMPLE" 'CURSOR_CONFIG_DIRS=' 'account config dirs must remain unset'
not_contains "$ENV_EXAMPLE" 'CURSOR_ACCOUNT_DIRS=' 'account dirs must remain unset'

for command in init build start status doctor smoke logs stop destroy; do
    contains "$BASH_SCRIPT" "$command" "Bash command missing: $command"
    contains "$PS_SCRIPT" "$command" "PowerShell command missing: $command"
done

if awk '/^cmd_doctor\(\)/,/^cmd_smoke\(\)/' "$BASH_SCRIPT" |
   grep -Eq 'compose (up|down|stop|restart|pull)|docker (build|run|stop|rm|pull)'; then
    fail 'Bash Doctor contains a mutating Docker command'
fi
if sed -n '/^function Invoke-PocDoctor/,/^function Invoke-PocSmoke/p' "$PS_SCRIPT" |
   grep -Eq 'Invoke-PocCompose.*(up|down|stop|restart|pull)|Invoke-Native.*(build|run|stop|rm|pull)'; then
    fail 'PowerShell Doctor contains a mutating Docker command'
fi
contains "$BASH_SCRIPT" 'compose down --remove-orphans' 'Bash destroy is not POC-scoped'
contains "$PS_SCRIPT" "Invoke-PocCompose @('down','--remove-orphans')" 'PowerShell destroy is not POC-scoped'

printf 'PASS: Cursor Bridge POC static contract is isolated and hardened\n'
```

- [ ] **Step 2: Write the matching PowerShell contract test**

```powershell
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$poc = Join-Path $root 'poc/cursor-bridge'
$compose = Join-Path $poc 'docker-compose.yml'
$envExample = Join-Path $poc 'poc.env.example'
$bashScript = Join-Path $poc 'poc.sh'
$psScript = Join-Path $poc 'poc.ps1'
$sourceCommit = 'c0ff1f941215027c0a8f658ca5d01f806559208f'

function Assert-Contains([string]$path, [string]$value, [string]$message) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "FAIL: missing $path" }
    if (-not (Select-String -LiteralPath $path -SimpleMatch $value -Quiet)) {
        throw "FAIL: $message"
    }
}
function Assert-NotContains([string]$path, [string]$value, [string]$message) {
    if (Select-String -LiteralPath $path -SimpleMatch $value -Quiet) {
        throw "FAIL: $message"
    }
}

Assert-Contains $bashScript $sourceCommit 'Bash source commit is not pinned'
Assert-Contains $psScript $sourceCommit 'PowerShell source commit is not pinned'
Assert-Contains $compose '127.0.0.1:${CURSOR_BRIDGE_POC_PORT:-18765}:8765' 'POC bind is not loopback-only'
Assert-NotContains $compose '0.0.0.0:${CURSOR_BRIDGE_POC_PORT' 'POC publishes a public host port'
Assert-Contains $compose 'pull_policy: never' 'POC image start policy is not fixed'
Assert-NotContains $compose 'latest' 'POC Compose must not use a latest tag'
Assert-NotContains $envExample 'latest' 'POC env example must not use a latest tag'
Assert-Contains $compose 'no-new-privileges:true' 'no-new-privileges is missing'
Assert-Contains $compose 'pids_limit: 128' 'PID limit is missing'
Assert-Contains $compose 'mem_limit: 2g' 'memory limit is missing'
Assert-Contains $compose 'cpus: "2.0"' 'CPU limit is missing'
Assert-NotContains $compose '/var/run/docker.sock' 'Docker socket must not be mounted'
Assert-NotContains $compose '/root/.cli-proxy-api' 'CPA auth volume must not be mounted'

foreach ($setting in @(
    'CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true',
    'CURSOR_BRIDGE_MODE=ask',
    'CURSOR_BRIDGE_FORCE=false',
    'CURSOR_BRIDGE_APPROVE_MCPS=false',
    'CURSOR_BRIDGE_VERBOSE=false',
    'CURSOR_BRIDGE_MAX_MODE=false',
    'CURSOR_BRIDGE_USE_ACP=true',
    'CURSOR_BRIDGE_ACP_RAW_DEBUG=false',
    'CURSOR_BRIDGE_MULTI_PORT=false'
)) {
    Assert-Contains $envExample $setting "missing safe setting $setting"
}

foreach ($command in @('init','build','start','status','doctor','smoke','logs','stop','destroy')) {
    Assert-Contains $bashScript $command "Bash command missing: $command"
    Assert-Contains $psScript $command "PowerShell command missing: $command"
}

$bashText = Get-Content -Raw -LiteralPath $bashScript
$bashDoctor = [regex]::Match($bashText, '(?ms)^cmd_doctor\(\).*?(?=^cmd_smoke\(\))').Value
if ($bashDoctor -match 'compose (up|down|stop|restart|pull)|docker (build|run|stop|rm|pull)') {
    throw 'FAIL: Bash Doctor contains a mutating Docker command'
}
$powerShellText = Get-Content -Raw -LiteralPath $psScript
$powerShellDoctor = [regex]::Match($powerShellText, '(?ms)^function Invoke-PocDoctor.*?(?=^function Invoke-PocSmoke)').Value
if ($powerShellDoctor -match 'Invoke-PocCompose.*(up|down|stop|restart|pull)|Invoke-Native.*(build|run|stop|rm|pull)') {
    throw 'FAIL: PowerShell Doctor contains a mutating Docker command'
}
Assert-Contains $bashScript 'compose down --remove-orphans' 'Bash destroy is not POC-scoped'
Assert-Contains $psScript "Invoke-PocCompose @('down','--remove-orphans')" 'PowerShell destroy is not POC-scoped'

Write-Host 'PASS: PowerShell Cursor Bridge POC contract matches the Bash contract'
```

- [ ] **Step 3: Run both tests and verify they fail because the POC files do not exist**

Run:

```bash
bash tests/test-cursor-bridge-poc-contract.sh
pwsh -NoProfile -File tests/test-cursor-bridge-poc-contract.ps1
```

Expected: both commands fail with a missing `poc/cursor-bridge` file.

- [ ] **Step 4: Commit the failing tests**

```bash
git add tests/test-cursor-bridge-poc-contract.sh tests/test-cursor-bridge-poc-contract.ps1
git commit -m "test(cursor-poc): define isolated bridge contract"
```

### Task 2: Add the secret and environment contract

**Files:**

- Create: `poc/cursor-bridge/poc.env.example`
- Modify: `.gitignore`
- Modify: `SECURITY.md`

- [ ] **Step 1: Add the exact non-secret environment example**

```dotenv
# Internal Cursor Bridge POC only. Copy to poc.env and chmod 600.
CURSOR_BRIDGE_POC_IMAGE=cursor-api-proxy:poc-c0ff1f9
CURSOR_BRIDGE_POC_PORT=18765

# Replace locally. Never commit either value and never reuse a CPA key.
CURSOR_API_KEY=replace-locally-with-cursor-dashboard-key
CURSOR_BRIDGE_API_KEY=replace-locally-with-random-64-hex-key

CURSOR_BRIDGE_HOST=0.0.0.0
CURSOR_BRIDGE_PORT=8765
CURSOR_BRIDGE_DEFAULT_MODEL=auto
CURSOR_BRIDGE_TIMEOUT_MS=300000
CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true
CURSOR_BRIDGE_MODE=ask
CURSOR_BRIDGE_FORCE=false
CURSOR_BRIDGE_APPROVE_MCPS=false
CURSOR_BRIDGE_STRICT_MODEL=true
CURSOR_BRIDGE_VERBOSE=false
CURSOR_BRIDGE_MAX_MODE=false
CURSOR_BRIDGE_USE_ACP=true
CURSOR_BRIDGE_PROMPT_VIA_STDIN=true
CURSOR_BRIDGE_ACP_RAW_DEBUG=false
CURSOR_BRIDGE_CONTEXT_PREAMBLE=true
CURSOR_BRIDGE_MULTI_PORT=false
```

- [ ] **Step 2: Ignore all generated POC state**

Add to `.gitignore` under runtime config and secrets:

```gitignore
poc/cursor-bridge/poc.env
poc/cursor-bridge/poc.env.tmp.*
poc/cursor-bridge/poc-metadata.json
poc/cursor-bridge/poc-evidence/
```

- [ ] **Step 3: Document the threat boundary in SECURITY.md**

Add a section that states:

```markdown
## Experimental Cursor Bridge POC

The Cursor Bridge POC is internal and disposable. It binds only to loopback and
must not be connected to Nginx, the live CPA container, CPAMP, Sub2API, a public
hostname, or a host workspace. Keep `poc/cursor-bridge/poc.env` mode `0600` and
use different values for `CURSOR_API_KEY` and `CURSOR_BRIDGE_API_KEY`.

The audited upstream commit processes dashboard/control routes before bridge-key
authentication and reads request bodies without an application size limit.
Loopback-only exposure and sequential operator tests are mandatory. Public,
shared, paid, multi-account, quota-avoidance, `reset-hwid`, agent, plan, MCP,
force, real-workspace, and billing uses are outside this POC and are production
STOP conditions.
```

- [ ] **Step 4: Re-run the contract tests**

Expected: tests still fail because Compose and command scripts are missing.

- [ ] **Step 5: Commit the environment boundary**

```bash
git add poc/cursor-bridge/poc.env.example .gitignore SECURITY.md
git commit -m "chore(cursor-poc): define secrets and safety boundary"
```

### Task 3: Add the isolated bridge Compose stack

**Files:**

- Create: `poc/cursor-bridge/docker-compose.yml`

- [ ] **Step 1: Add the bridge-only Compose file**

```yaml
name: cursor-bridge-poc

services:
  cursor-bridge:
    image: ${CURSOR_BRIDGE_POC_IMAGE:-cursor-api-proxy:poc-c0ff1f9}
    pull_policy: never
    container_name: cursor-bridge-poc
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    ports:
      - "127.0.0.1:${CURSOR_BRIDGE_POC_PORT:-18765}:8765"
    env_file:
      - ./poc.env
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    pids_limit: 128
    mem_limit: 2g
    mem_reservation: 512m
    cpus: "2.0"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8765/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    networks:
      - cursor-bridge-poc-network

networks:
  cursor-bridge-poc-network:
    name: cursor-bridge-poc-network
    driver: bridge
```

- [ ] **Step 2: Validate Compose with a temporary non-secret env file**

Run:

```bash
test ! -e poc/cursor-bridge/poc.env
cp poc/cursor-bridge/poc.env.example poc/cursor-bridge/poc.env
trap 'rm -f poc/cursor-bridge/poc.env' EXIT
docker compose --env-file poc/cursor-bridge/poc.env \
  -f poc/cursor-bridge/docker-compose.yml config --quiet
rm -f poc/cursor-bridge/poc.env
trap - EXIT
```

Expected: exit code `0`; no container is created.

- [ ] **Step 3: Re-run the static contract tests**

Expected: tests still fail because lifecycle scripts are missing.

- [ ] **Step 4: Commit the Compose boundary**

```bash
git add poc/cursor-bridge/docker-compose.yml
git commit -m "feat(cursor-poc): add loopback-only bridge stack"
```

### Task 4: Add the Bash POC lifecycle and acceptance commands

**Files:**

- Create: `poc/cursor-bridge/poc.sh`

- [ ] **Step 1: Implement fixed paths, safe env parsing, and validation**

The script must use these constants and must not source `poc.env`:

```bash
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
readonly IMAGE_TAG="cursor-api-proxy:poc-c0ff1f9"

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
    COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

curl_auth() {
    local bridge_key="$1"
    shift
    printf 'header = "Authorization: Bearer %s"\n' "$bridge_key" |
      curl --config - "$@"
}
```

- [ ] **Step 2: Implement `init` and `build`**

`init` copies the example through a mode-`0600` temporary file, generates the
bridge key with OpenSSL, and never prints it. `build` uses the exact Git commit:

```bash
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
```

- [ ] **Step 3: Implement lifecycle and read-only status**

```bash
cmd_start() { require_env; compose config --quiet; compose up -d; }
cmd_stop() { require_env; compose stop; }
cmd_destroy() { require_env; compose down --remove-orphans; }
cmd_logs() { require_env; compose logs --tail 200 cursor-bridge; }
cmd_status() {
    require_env
    compose ps
    docker inspect "$CONTAINER_NAME" --format \
      'User={{.Config.User}} Image={{.Image}} Restart={{.RestartCount}} OOM={{.State.OOMKilled}} Ports={{json .HostConfig.PortBindings}}'
}
```

`destroy` must not delete `poc.env`, metadata, images, or any non-POC object.

- [ ] **Step 4: Implement Doctor and smoke acceptance**

Doctor must read keys without printing them, assert loopback binding, test auth,
safe mode, model discovery, container limits, and secret-free logs. Smoke must run
one synchronous request followed by one streaming request. Use the exact
acceptance behavior:

```bash
cmd_doctor() {
    require_env
    command -v curl >/dev/null || fail 'curl is required'
    command -v jq >/dev/null || fail 'jq is required'
    local port bridge_key cursor_key base unauth models logs
    port="$(env_value CURSOR_BRIDGE_POC_PORT)"; port="${port:-18765}"
    bridge_key="$(env_value CURSOR_BRIDGE_API_KEY)"
    cursor_key="$(env_value CURSOR_API_KEY)"
    base="http://127.0.0.1:${port}"
    [[ "$(docker port "$CONTAINER_NAME" 8765/tcp)" == "127.0.0.1:${port}" ]] || fail 'bridge is not loopback-only'
    [[ "$(curl -fsS "$base/healthz")" == ok ]] || fail 'liveness failed'
    unauth="$(curl -sS -o /dev/null -w '%{http_code}' "$base/v1/models")"
    [[ "$unauth" == 401 ]] || fail "unauthenticated models returned ${unauth}"
    curl_auth "$bridge_key" -fsS "$base/health" |
      jq -e '.ok == true and .mode == "ask" and .force == false and .approveMcps == false' >/dev/null
    models="$(curl_auth "$bridge_key" -fsS --max-time 70 "$base/v1/models")"
    printf '%s' "$models" | jq -e '.object == "list" and (.data | length) > 0' >/dev/null
    logs="$(docker logs "$CONTAINER_NAME" 2>&1 || true)"
    [[ "$logs" != *"$bridge_key"* && "$logs" != *"$cursor_key"* ]] || fail 'a credential appears in logs'
    docker inspect "$CONTAINER_NAME" --format '{{.Config.User}} {{.HostConfig.Memory}} {{.HostConfig.PidsLimit}} {{json .HostConfig.SecurityOpt}} {{json .HostConfig.CapDrop}}' |
      grep -F 'app 2147483648 128' >/dev/null || fail 'container resource/user contract failed'
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
    model="$(printf '%s' "$models" | jq -r '.data[0].id')"
    curl_auth "$bridge_key" -fsS --max-time 180 \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply with exactly CURSOR_POC_OK"}],stream:false}')" \
      "$base/v1/chat/completions" |
      jq -e '.choices[0].message.content | contains("CURSOR_POC_OK")' >/dev/null
    curl_auth "$bridge_key" -sSN --max-time 180 \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply with exactly STREAM_OK"}],stream:true}')" \
      "$base/v1/chat/completions" | grep -m1 '^data:' >/dev/null
    info 'Smoke PASS'
}
```

- [ ] **Step 5: Add the exact command dispatcher**

```bash
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
```

- [ ] **Step 6: Run syntax and static tests**

```bash
chmod +x poc/cursor-bridge/poc.sh
bash -n poc/cursor-bridge/poc.sh
bash tests/test-cursor-bridge-poc-contract.sh
```

Expected: Bash syntax passes; the contract test now fails only because the
PowerShell script is missing.

- [ ] **Step 7: Commit the Bash lifecycle**

```bash
git add poc/cursor-bridge/poc.sh
git commit -m "feat(cursor-poc): add Bash bridge lifecycle"
```

### Task 5: Add matching PowerShell lifecycle behavior

**Files:**

- Create: `poc/cursor-bridge/poc.ps1`

- [ ] **Step 1: Mirror constants and safe env parsing**

Use the same project, container, source commit, image tag, commands, and error
behavior. Parse `poc.env` as data rather than dot-sourcing it:

```powershell
$ErrorActionPreference = 'Stop'
$script:ScriptDir = $PSScriptRoot
$script:ComposeFile = Join-Path $PSScriptRoot 'docker-compose.yml'
$script:EnvFile = Join-Path $PSScriptRoot 'poc.env'
$script:EnvExample = Join-Path $PSScriptRoot 'poc.env.example'
$script:MetadataFile = Join-Path $PSScriptRoot 'poc-metadata.json'
$script:ProjectName = 'cursor-bridge-poc'
$script:ContainerName = 'cursor-bridge-poc'
$script:SourceRepository = 'https://github.com/anyrobert/cursor-api-proxy'
$script:SourceCommit = 'c0ff1f941215027c0a8f658ca5d01f806559208f'
$script:ImageTag = 'cursor-api-proxy:poc-c0ff1f9'

function Fail([string]$Message) { throw "ERROR: $Message" }
function Get-PocEnv([string]$Name) {
    if (-not (Test-Path $script:EnvFile -PathType Leaf)) { Fail 'run: .\poc.ps1 init' }
    foreach ($line in Get-Content -LiteralPath $script:EnvFile) {
        if ($line -match '^([^#=]+)=(.*)$' -and $Matches[1].Trim() -eq $Name) {
            return $Matches[2].Trim()
        }
    }
    return ''
}
function Assert-PocEnv {
    $cursorKey = Get-PocEnv 'CURSOR_API_KEY'
    $bridgeKey = Get-PocEnv 'CURSOR_BRIDGE_API_KEY'
    if (-not $cursorKey -or $cursorKey.StartsWith('replace-locally-')) { Fail 'CURSOR_API_KEY is not configured' }
    if ($bridgeKey -notmatch '^[A-Fa-f0-9]{64}$') { Fail 'CURSOR_BRIDGE_API_KEY must be 64 hex characters' }
    if ($cursorKey -eq $bridgeKey) { Fail 'Cursor and bridge keys must be different' }
}
function Invoke-PocCompose([string[]]$Arguments) {
    $previous = $env:COMPOSE_PROJECT_NAME
    $env:COMPOSE_PROJECT_NAME = $script:ProjectName
    try { & docker compose --env-file $script:EnvFile -f $script:ComposeFile @Arguments }
    finally {
        if ($null -eq $previous) { Remove-Item Env:COMPOSE_PROJECT_NAME -ErrorAction SilentlyContinue }
        else { $env:COMPOSE_PROJECT_NAME = $previous }
    }
    if ($LASTEXITCODE -ne 0) { Fail "docker compose failed: $($Arguments -join ' ')" }
}
```

- [ ] **Step 2: Implement the same nine commands**

Append the complete lifecycle, Doctor, smoke, and dispatcher implementation:

```powershell
function Invoke-Native([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { Fail "$File failed with exit code $LASTEXITCODE" }
}

function Invoke-PocInit {
    if (Test-Path $script:EnvFile) { Fail 'poc.env already exists' }
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $bridgeKey = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $content = (Get-Content -Raw -LiteralPath $script:EnvExample).Replace(
        'replace-locally-with-random-64-hex-key', $bridgeKey)
    $temporary = "$($script:EnvFile).tmp.$([guid]::NewGuid().ToString('N'))"
    $encoding = [Text.UTF8Encoding]::new($false)
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer = [IO.StreamWriter]::new($stream, $encoding)
        try { $writer.Write($content) } finally { $writer.Dispose() }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    Move-Item -LiteralPath $temporary -Destination $script:EnvFile
    if (-not $IsWindows) { & chmod 600 $script:EnvFile }
    Write-Host 'INFO: Created poc.env. Edit CURSOR_API_KEY locally before build/start.'
}

function Invoke-PocBuild {
    Assert-PocEnv
    Invoke-Native docker @(
        'buildx','build','--load',
        '--label',"org.opencontainers.image.source=$($script:SourceRepository)",
        '--label',"org.opencontainers.image.revision=$($script:SourceCommit)",
        '-t',$script:ImageTag,
        "$($script:SourceRepository).git#$($script:SourceCommit)"
    )
    $imageId = (& docker image inspect $script:ImageTag --format '{{.Id}}').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $imageId) { Fail 'cannot inspect the built image' }
    [ordered]@{
        source_commit = $script:SourceCommit
        image = $script:ImageTag
        image_id = $imageId
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:MetadataFile -NoNewline
    if (-not $IsWindows) { & chmod 600 $script:MetadataFile }
    Write-Host "INFO: Built and recorded $($script:ImageTag)"
}

function Invoke-PocStart {
    Assert-PocEnv
    Invoke-PocCompose @('config','--quiet')
    Invoke-PocCompose @('up','-d')
}
function Invoke-PocStop { Assert-PocEnv; Invoke-PocCompose @('stop') }
function Invoke-PocDestroy { Assert-PocEnv; Invoke-PocCompose @('down','--remove-orphans') }
function Invoke-PocLogs { Assert-PocEnv; Invoke-PocCompose @('logs','--tail','200','cursor-bridge') }
function Invoke-PocStatus {
    Assert-PocEnv
    Invoke-PocCompose @('ps')
    Invoke-Native docker @(
        'inspect',$script:ContainerName,'--format',
        'User={{.Config.User}} Image={{.Image}} Restart={{.RestartCount}} OOM={{.State.OOMKilled}} Ports={{json .HostConfig.PortBindings}}'
    )
}

function Invoke-PocDoctor {
    Assert-PocEnv
    $port = Get-PocEnv 'CURSOR_BRIDGE_POC_PORT'; if (-not $port) { $port = '18765' }
    $bridgeKey = Get-PocEnv 'CURSOR_BRIDGE_API_KEY'
    $cursorKey = Get-PocEnv 'CURSOR_API_KEY'
    $base = "http://127.0.0.1:$port"
    $binding = (& docker port $script:ContainerName '8765/tcp').Trim()
    if ($LASTEXITCODE -ne 0 -or $binding -ne "127.0.0.1:$port") { Fail 'bridge is not loopback-only' }
    $healthz = Invoke-WebRequest -Uri "$base/healthz" -Method Get -TimeoutSec 10
    if ($healthz.Content.Trim() -ne 'ok') { Fail 'liveness failed' }
    $unauthorized = Invoke-WebRequest -Uri "$base/v1/models" -Method Get -SkipHttpErrorCheck -TimeoutSec 10
    if ([int]$unauthorized.StatusCode -ne 401) { Fail "unauthenticated models returned $($unauthorized.StatusCode)" }
    $headers = @{ Authorization = "Bearer $bridgeKey" }
    $health = Invoke-RestMethod -Uri "$base/health" -Headers $headers -TimeoutSec 10
    if (-not $health.ok -or $health.mode -ne 'ask' -or $health.force -ne $false -or $health.approveMcps -ne $false) {
        Fail 'safe health contract failed'
    }
    $models = Invoke-RestMethod -Uri "$base/v1/models" -Headers $headers -TimeoutSec 70
    if ($models.object -ne 'list' -or @($models.data).Count -eq 0) { Fail 'model discovery failed' }
    $logs = (& docker logs $script:ContainerName 2>&1) -join "`n"
    if ($logs.Contains($bridgeKey) -or $logs.Contains($cursorKey)) { Fail 'a credential appears in logs' }
    $inspect = ((& docker inspect $script:ContainerName) -join "`n" | ConvertFrom-Json)[0]
    if ($inspect.Config.User -ne 'app') { Fail 'container user is not app' }
    if ([int64]$inspect.HostConfig.Memory -ne 2147483648) { Fail 'memory limit is not 2 GiB' }
    if ([int64]$inspect.HostConfig.PidsLimit -ne 128) { Fail 'PID limit is not 128' }
    if (@($inspect.HostConfig.SecurityOpt) -notcontains 'no-new-privileges:true') { Fail 'no-new-privileges is missing' }
    if (@($inspect.HostConfig.CapDrop) -notcontains 'ALL') { Fail 'ALL capabilities are not dropped' }
    Write-Host 'INFO: Doctor PASS'
}

function Invoke-PocSmoke {
    Assert-PocEnv
    $port = Get-PocEnv 'CURSOR_BRIDGE_POC_PORT'; if (-not $port) { $port = '18765' }
    $bridgeKey = Get-PocEnv 'CURSOR_BRIDGE_API_KEY'
    $base = "http://127.0.0.1:$port"
    $headers = @{ Authorization = "Bearer $bridgeKey" }
    $models = Invoke-RestMethod -Uri "$base/v1/models" -Headers $headers -TimeoutSec 70
    $model = @($models.data)[0].id
    $syncBody = [ordered]@{
        model = $model
        messages = @([ordered]@{ role = 'user'; content = 'Reply with exactly CURSOR_POC_OK' })
        stream = $false
    } | ConvertTo-Json -Depth 6 -Compress
    $sync = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Headers $headers `
        -ContentType 'application/json' -Method Post -Body $syncBody -TimeoutSec 180
    if ($sync.choices[0].message.content -notlike '*CURSOR_POC_OK*') { Fail 'synchronous smoke failed' }
    $streamBody = [ordered]@{
        model = $model
        messages = @([ordered]@{ role = 'user'; content = 'Reply with exactly STREAM_OK' })
        stream = $true
    } | ConvertTo-Json -Depth 6 -Compress
    $stream = Invoke-WebRequest -Uri "$base/v1/chat/completions" -Headers $headers `
        -ContentType 'application/json' -Method Post -Body $streamBody -TimeoutSec 180
    if ($stream.Content -notmatch '(?m)^data:') { Fail 'streaming smoke failed' }
    Write-Host 'INFO: Smoke PASS'
}

function Invoke-Main([string[]]$Arguments) {
    $command = if ($Arguments.Count -gt 0) { $Arguments[0] } else { 'help' }
    switch ($command) {
        'init' { Invoke-PocInit }
        'build' { Invoke-PocBuild }
        'start' { Invoke-PocStart }
        'status' { Invoke-PocStatus }
        'doctor' { Invoke-PocDoctor }
        'smoke' { Invoke-PocSmoke }
        'logs' { Invoke-PocLogs }
        'stop' { Invoke-PocStop }
        'destroy' { Invoke-PocDestroy }
        'help' { Write-Host 'Usage: .\poc.ps1 init|build|start|status|doctor|smoke|logs|stop|destroy' }
        '--help' { Write-Host 'Usage: .\poc.ps1 init|build|start|status|doctor|smoke|logs|stop|destroy' }
        '-h' { Write-Host 'Usage: .\poc.ps1 init|build|start|status|doctor|smoke|logs|stop|destroy' }
        default { Fail "unknown command: $command" }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main -Arguments $args }
```

- [ ] **Step 3: Parse-test PowerShell and run both contracts**

```powershell
pwsh -NoProfile -Command "try { . .\poc\cursor-bridge\poc.ps1 } catch { throw }"
pwsh -NoProfile -File tests/test-cursor-bridge-poc-contract.ps1
```

Then run:

```bash
bash tests/test-cursor-bridge-poc-contract.sh
```

Expected: both contract tests pass.

- [ ] **Step 4: Commit the PowerShell lifecycle**

```bash
git add poc/cursor-bridge/poc.ps1
git commit -m "feat(cursor-poc): add PowerShell bridge lifecycle"
```

### Task 6: Add the operator guide and root documentation link

**Files:**

- Create: `poc/cursor-bridge/README.md`
- Modify: `README.md`

- [ ] **Step 1: Document the exact safe sequence**

The POC README must contain:

```text
bash poc.sh init
# edit only CURSOR_API_KEY in poc.env
bash poc.sh build
bash poc.sh start
bash poc.sh doctor
bash poc.sh smoke
bash poc.sh status
bash poc.sh stop
bash poc.sh destroy
```

Include matching PowerShell commands, the SSH tunnel example
`ssh -L 18765:127.0.0.1:18765 "$CURSOR_POC_SSH_TARGET"`, the three-key explanation, supported
and unsupported endpoints, Stage A acceptance gates, evidence fields, and every
STOP condition from the approved design.

State prominently:

```markdown
This Stage A POC does not connect to CPA or Nginx. Passing Stage A authorizes only
the creation of a separate Stage B design; it does not authorize production use.
```

- [ ] **Step 2: Add one root README entry without changing existing dirty guides**

Add a short experimental link in the optional integrations area:

```markdown
- [Experimental internal Cursor Bridge POC](poc/cursor-bridge/README.md) —
  loopback-only Stage A validation; not a public deployment.
```

Do not reformat the file and preserve the existing image/video guide additions.

- [ ] **Step 3: Run link and secret-pattern checks**

```bash
test -f poc/cursor-bridge/README.md
grep -Fq 'Experimental internal Cursor Bridge POC' README.md
! grep -RInE 'sk-[A-Za-z0-9_-]{12,}|CURSOR_API_KEY=[^r][^e][^p]' \
  poc/cursor-bridge README.md SECURITY.md
```

Expected: all checks exit `0` and no real credential is found.

- [ ] **Step 4: Commit documentation**

```bash
git add poc/cursor-bridge/README.md README.md
git commit -m "docs(cursor-poc): add internal Stage A guide"
```

### Task 7: Run non-live repository verification

**Files:** none

- [ ] **Step 1: Run syntax and contract tests**

```bash
bash -n poc/cursor-bridge/poc.sh
pwsh -NoProfile -Command "try { . .\poc\cursor-bridge\poc.ps1 } catch { throw }"
bash tests/test-cursor-bridge-poc-contract.sh
pwsh -NoProfile -File tests/test-cursor-bridge-poc-contract.ps1
bash -n deploy.sh install.sh
pwsh -NoProfile -Command "try { . .\deploy.ps1 } catch {}"
docker compose -f docker-compose.yml config --quiet
test ! -e poc/cursor-bridge/poc.env
cp poc/cursor-bridge/poc.env.example poc/cursor-bridge/poc.env
trap 'rm -f poc/cursor-bridge/poc.env' EXIT
docker compose --env-file poc/cursor-bridge/poc.env \
  -f poc/cursor-bridge/docker-compose.yml config --quiet
rm -f poc/cursor-bridge/poc.env
trap - EXIT
git diff --check
```

Expected: all commands pass. Existing CPA and Sub2API behavior remains unchanged.

- [ ] **Step 2: Confirm isolation from the production surface**

```bash
git diff --name-only HEAD~6..HEAD
```

Expected changed paths are limited to:

```text
.gitignore
README.md
SECURITY.md
poc/cursor-bridge/**
tests/test-cursor-bridge-poc-contract.sh
tests/test-cursor-bridge-poc-contract.ps1
```

- [ ] **Step 3: Handle verification corrections without a catch-all commit**

If verification finds a problem, return to the task that owns that file, apply
the correction there, rerun that task's checks, and amend that task's commit. If
no correction is required, do not create an empty commit.

### Task 8: Run the explicitly authorized live Stage A acceptance

**Files:** runtime-only ignored files under `poc/cursor-bridge/`

This task requires the operator's Cursor key and Docker/network access. It must
not run automatically in CI or during ordinary repository tests.

- [ ] **Step 1: Initialize and locally enter the Cursor key**

```bash
cd poc/cursor-bridge
bash poc.sh init
chmod 600 poc.env
```

Edit `CURSOR_API_KEY` locally. Never paste it into the task conversation, shell
history, screenshots, Git, or logs.

- [ ] **Step 2: Build the exact source commit and record evidence**

```bash
bash poc.sh build
docker image inspect cursor-api-proxy:poc-c0ff1f9 --format '{{.Id}} {{json .Config.Labels}}'
```

Expected: revision label equals the full pinned commit. Record the image ID.

- [ ] **Step 3: Start, diagnose, and run sequential smoke tests**

```bash
bash poc.sh start
bash poc.sh doctor
bash poc.sh smoke
bash poc.sh status
docker exec cursor-bridge-poc agent --version
docker exec cursor-bridge-poc agent --list-models
```

Expected: Doctor and smoke pass; user is `app`; restart count is zero; OOM is
false; models are non-empty.

- [ ] **Step 4: Verify remote isolation**

From a different machine without an SSH tunnel:

```bash
: "${CURSOR_POC_PUBLIC_IP:?export CURSOR_POC_PUBLIC_IP first}"
curl --connect-timeout 5 "http://${CURSOR_POC_PUBLIC_IP}:18765/healthz"
```

Expected: connection fails. On the server:

```bash
docker port cursor-bridge-poc 8765/tcp
```

Expected: exactly `127.0.0.1:18765`.

- [ ] **Step 5: Capture redacted evidence and stop**

Record only:

- source commit;
- image ID;
- Cursor CLI version;
- model count, not model/account secrets;
- Doctor/smoke pass/fail;
- restart count, OOM state, memory, and PIDs;
- remote isolation result;
- known mutable Node base/Cursor installer limitation.

Then stop the POC:

```bash
bash poc.sh stop
```

Do not connect CPA or Nginx. Return the evidence to the project lead for the
Stage A GO/REWORK/NO-GO decision.

---

## Self-review checklist

- Every Stage A requirement in the approved design maps to a task above.
- There is no task that edits or restarts live CPA, Nginx, Sub2API, or CPAMP.
- The source commit is exact and appears in tests plus both lifecycle scripts.
- No `latest`, public binding, host workspace, Docker socket, CPA auth volume, or
  production config is part of the POC runtime.
- Bash and PowerShell command surfaces match.
- Ordinary tests are secret-free and do not build, start, pull, or deploy.
- Live acceptance is explicit, sequential, manually authorized, and stops before
  any CPA integration.
