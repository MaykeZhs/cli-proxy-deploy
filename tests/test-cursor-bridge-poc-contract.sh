#!/usr/bin/env bash
# Cursor Bridge Stage A static contract.
# Bash 3.2 compatible: no associative arrays, ${var^}, or mapfile.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POC_DIR="$ROOT_DIR/poc/cursor-bridge"
COMPOSE_FILE="$POC_DIR/docker-compose.yml"
ENV_EXAMPLE="$POC_DIR/poc.env.example"
POC_SH="$POC_DIR/poc.sh"
POC_PS1="$POC_DIR/poc.ps1"
SOURCE_COMMIT="c0ff1f941215027c0a8f658ca5d01f806559208f"
SOURCE_REPOSITORY="https://github.com/anyrobert/cursor-api-proxy"
EXPECTED_IMAGE="cursor-api-proxy:poc-$SOURCE_COMMIT"
EXPECTED_PORT_LINE='127.0.0.1:${CURSOR_BRIDGE_POC_PORT:-18765}:8765'
PROJECT_NAME="cursor-bridge-poc"
COMMANDS="init build start status doctor smoke logs stop destroy"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

require_python() {
  if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
  elif command -v python >/dev/null 2>&1; then
    PYTHON=python
  else
    fail "python3 is required to parse docker compose --format json"
  fi
}

# Keep the first missing-file message stable for the Task 1 RED gate.
for rel in \
  poc/cursor-bridge/docker-compose.yml \
  poc/cursor-bridge/poc.env.example \
  poc/cursor-bridge/poc.sh \
  poc/cursor-bridge/poc.ps1
do
  [ -f "$ROOT_DIR/$rel" ] || fail "Missing required POC file: $rel"
done

contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
not_contains() { ! grep -Fq -- "$2" "$1" || fail "$3"; }

strip_cr() { tr -d '\r' < "$1"; }

bash_function_body() {
  awk -v name="$1" '
    $0 ~ "^[[:space:]]*(function[[:space:]]+)?" name "([[:space:]]*\\(\\))?[[:space:]]*\\{" { active = 1 }
    active && $0 !~ "^[[:space:]]*(function[[:space:]]+)?" name "([[:space:]]*\\(\\))?[[:space:]]*\\{" && $0 ~ "^[[:space:]]*(function[[:space:]]+)?[[:alpha:]_][[:alnum:]_]*([[:space:]]*\\(\\))?[[:space:]]*\\{" { exit }
    active { print }
  ' "$POC_SH"
}

ps_function_body() {
  awk -v name="$1" '
    BEGIN { target = tolower(name) }
    /^[[:space:]]*function[[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, parts, /[[:space:]]+/)
      fname = tolower(parts[2])
      if (active && fname != target) exit
      if (fname == target) active = 1
    }
    active { print }
  ' "$POC_PS1"
}

list_bash_functions() {
  awk '
    /^[[:space:]]*(function[[:space:]]+)?[[:alpha:]_][[:alnum:]_]*([[:space:]]*\(\))?[[:space:]]*\{/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^function[[:space:]]+/, "", line)
      sub(/[[:space:]]*\(.*/, "", line)
      sub(/[[:space:]]*\{.*/, "", line)
      print line
    }
  ' "$POC_SH"
}

list_ps_functions() {
  awk '
    /^[[:space:]]*function[[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, parts, /[[:space:]]+/)
      print parts[2]
    }
  ' "$POC_PS1"
}

assert_exact_assignment() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  local count
  count="$(grep -Ec "$pattern" "$file" || true)"
  [ "$count" -eq 1 ] || fail "$message"
}

# --- Source-level pins that Compose JSON would otherwise normalize away. ---
image_lines="$(strip_cr "$COMPOSE_FILE" | grep -E '^[[:space:]]*image:[[:space:]]*' || true)"
image_count="$(printf '%s\n' "$image_lines" | grep -c . || true)"
[ "$image_count" -eq 1 ] || fail "Compose must define exactly one image: line"
image_line="$(printf '%s\n' "$image_lines" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
[ "$image_line" = "image: $EXPECTED_IMAGE" ] || fail "Compose image must be hard-coded as $EXPECTED_IMAGE"
printf '%s\n' "$image_line" | grep -Fq '$' && fail "Compose image must not use a variable or default interpolation"

contains "$COMPOSE_FILE" "$EXPECTED_PORT_LINE" "Compose source must use the exact loopback mapping $EXPECTED_PORT_LINE"
not_contains "$COMPOSE_FILE" 'CURSOR_BRIDGE_POC_IMAGE' "Compose must not accept a CURSOR_BRIDGE_POC_IMAGE override"
not_contains "$ENV_EXAMPLE" 'CURSOR_BRIDGE_POC_IMAGE' "Environment example must not define CURSOR_BRIDGE_POC_IMAGE"
not_contains "$ENV_EXAMPLE" 'latest' "Environment example must not use a latest tag"

env_effective="$(strip_cr "$ENV_EXAMPLE" | sed -E '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/[[:space:]]*#.*$//')"
for setting in \
  CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true \
  CURSOR_BRIDGE_MODE=ask \
  CURSOR_BRIDGE_FORCE=false \
  CURSOR_BRIDGE_APPROVE_MCPS=false \
  CURSOR_BRIDGE_VERBOSE=false \
  CURSOR_BRIDGE_MAX_MODE=false \
  CURSOR_BRIDGE_USE_ACP=true \
  CURSOR_BRIDGE_ACP_RAW_DEBUG=false \
  CURSOR_BRIDGE_MULTI_PORT=false
do
  setting_name="${setting%%=*}"
  setting_lines="$(printf '%s\n' "$env_effective" | grep -E "^${setting_name}=" || true)"
  [ "$(printf '%s\n' "$setting_lines" | grep -c . || true)" -eq 1 ] || fail "Environment example must define exactly one $setting"
  [ "$setting_lines" = "$setting" ] || fail "Environment example must set $setting"
done
printf '%s\n' "$env_effective" | grep -Fq 'CURSOR_CONFIG_DIRS=' && fail "Environment example must not define CURSOR_CONFIG_DIRS"
printf '%s\n' "$env_effective" | grep -Fq 'CURSOR_ACCOUNT_DIRS=' && fail "Environment example must not define CURSOR_ACCOUNT_DIRS"

# --- Effective Compose contract via the Compose JSON parser. ---
require_python
docker compose version >/dev/null 2>&1 || fail "docker compose is required to validate the effective POC stack"
COMPOSE_JSON="$(docker compose --env-file "$ENV_EXAMPLE" -f "$COMPOSE_FILE" config --format json)" || fail "docker compose config --format json failed"
export COMPOSE_CONTRACT_IMAGE="$EXPECTED_IMAGE"
export COMPOSE_CONTRACT_PROJECT="$PROJECT_NAME"
printf '%s' "$COMPOSE_JSON" | "$PYTHON" -c '
import json, os, sys

cfg = json.load(sys.stdin)
expected_image = os.environ["COMPOSE_CONTRACT_IMAGE"]
expected_project = os.environ["COMPOSE_CONTRACT_PROJECT"]

def fail(message):
    sys.stderr.write("FAIL: %s\n" % message)
    sys.exit(1)

if cfg.get("name") != expected_project:
    fail("Compose project name must be %s" % expected_project)

services = cfg.get("services") or {}
names = list(services.keys())
if names != ["cursor-bridge"]:
    fail("Compose must define exactly one service: cursor-bridge")

svc = services["cursor-bridge"]
if svc.get("image") != expected_image:
    fail("Effective image must be %s" % expected_image)
if svc.get("build"):
    fail("Compose must not declare a build section")
if svc.get("pull_policy") != "never":
    fail("pull_policy must be never")

ports = svc.get("ports") or []
if len(ports) != 1:
    fail("Compose must publish exactly one host mapping")
port = ports[0]
if (
    port.get("host_ip") != "127.0.0.1"
    or int(port.get("target") or 0) != 8765
    or str(port.get("published")) != "18765"
    or port.get("protocol") != "tcp"
):
    fail("Effective publish must be 127.0.0.1:18765:8765/tcp")

expose = svc.get("expose") or []
if expose:
    fail("Compose must not declare expose, including 8765")

if svc.get("privileged") is True:
    fail("privileged must not be enabled")
if svc.get("network_mode") == "host":
    fail("network_mode must not be host")
if svc.get("pid") == "host":
    fail("pid mode must not be host")
if svc.get("ipc") == "host":
    fail("ipc mode must not be host")

for key in ("volumes", "volumes_from", "devices", "configs", "secrets", "tmpfs"):
    value = svc.get(key)
    if value:
        fail("cursor-bridge must not define %s" % key)

if list(svc.get("cap_drop") or []) != ["ALL"]:
    fail("cap_drop must be ALL")
if "no-new-privileges:true" not in list(svc.get("security_opt") or []):
    fail("security_opt must include no-new-privileges:true")
if svc.get("pids_limit") != 128:
    fail("pids_limit must be 128")
if int(svc.get("mem_limit") or 0) != 2147483648:
    fail("memory must be 2 GiB")
if svc.get("cpus") not in (2, 2.0):
    fail("CPUs must be 2")
if svc.get("init") is not True:
    fail("init must be true")

env = svc.get("environment")
if not isinstance(env, dict):
    fail("Compose must use an explicit environment map")
if svc.get("env_file"):
    fail("Compose must not use env_file; keep an explicit environment map")

required = {
    "CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE": "true",
    "CURSOR_BRIDGE_MODE": "ask",
    "CURSOR_BRIDGE_FORCE": "false",
    "CURSOR_BRIDGE_APPROVE_MCPS": "false",
    "CURSOR_BRIDGE_VERBOSE": "false",
    "CURSOR_BRIDGE_MAX_MODE": "false",
    "CURSOR_BRIDGE_USE_ACP": "true",
    "CURSOR_BRIDGE_ACP_RAW_DEBUG": "false",
    "CURSOR_BRIDGE_MULTI_PORT": "false",
}
for key, value in required.items():
    if str(env.get(key)) != value:
        fail("effective environment %s must be %s" % (key, value))
for key in ("CURSOR_CONFIG_DIRS", "CURSOR_ACCOUNT_DIRS"):
    if key in env:
        fail("%s must remain unset" % key)

for net_name, net in (cfg.get("networks") or {}).items():
    if net.get("external"):
        fail("POC networks must not be external")
    joined = "%s %s" % (net_name, net.get("name") or "")
    if "cli-proxy" in joined or "sub2api" in joined:
        fail("POC must not join a live CPA or Sub2API network")
'

# --- Native parse and pin usage. ---
bash -n "$POC_SH" || fail "poc.sh must pass bash -n"
if command -v pwsh >/dev/null 2>&1; then
  POC_PS1_NATIVE="$POC_PS1"
  if command -v cygpath >/dev/null 2>&1; then
    POC_PS1_NATIVE="$(cygpath -w "$POC_PS1")"
  fi
  POC_PS1_NATIVE="$POC_PS1_NATIVE" pwsh -NoProfile -Command '
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($env:POC_PS1_NATIVE, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw $errors[0].Message }
  ' || fail "poc.ps1 must parse"
fi

assert_exact_assignment "$POC_SH" "^[[:space:]]*(readonly[[:space:]]+)?SOURCE_COMMIT=['\"]$SOURCE_COMMIT['\"][[:space:]]*$" "poc.sh must assign SOURCE_COMMIT exactly once"
assert_exact_assignment "$POC_SH" "^[[:space:]]*(readonly[[:space:]]+)?SOURCE_REPOSITORY=['\"]$SOURCE_REPOSITORY['\"][[:space:]]*$" "poc.sh must pin SOURCE_REPOSITORY"
assert_exact_assignment "$POC_SH" "^[[:space:]]*(readonly[[:space:]]+)?IMAGE_TAG=['\"]$EXPECTED_IMAGE['\"][[:space:]]*$" "poc.sh must hard-code IMAGE_TAG to $EXPECTED_IMAGE"
assert_exact_assignment "$POC_SH" "^[[:space:]]*(readonly[[:space:]]+)?PROJECT_NAME=['\"]$PROJECT_NAME['\"][[:space:]]*$" "poc.sh must use project $PROJECT_NAME"
assert_exact_assignment "$POC_PS1" "^[[:space:]]*\\\$script:SourceCommit[[:space:]]*=[[:space:]]*['\"]$SOURCE_COMMIT['\"][[:space:]]*$" "poc.ps1 must assign script:SourceCommit exactly once"
assert_exact_assignment "$POC_PS1" "^[[:space:]]*\\\$script:SourceRepository[[:space:]]*=[[:space:]]*['\"]$SOURCE_REPOSITORY['\"][[:space:]]*$" "poc.ps1 must pin script:SourceRepository"
assert_exact_assignment "$POC_PS1" "^[[:space:]]*\\\$script:ImageTag[[:space:]]*=[[:space:]]*['\"]$EXPECTED_IMAGE['\"][[:space:]]*$" "poc.ps1 must hard-code script:ImageTag"
assert_exact_assignment "$POC_PS1" "^[[:space:]]*\\\$script:ProjectName[[:space:]]*=[[:space:]]*['\"]$PROJECT_NAME['\"][[:space:]]*$" "poc.ps1 must use project $PROJECT_NAME"

bash_dispatch="$(sed -nE '/^[[:space:]]*case[[:space:]]+"\$\{1:-help\}"[[:space:]]+in/,/^[[:space:]]*esac/p' "$POC_SH")"
[ -n "$bash_dispatch" ] || fail "poc.sh must dispatch through the real top-level case"
ps_main="$(ps_function_body Invoke-Main)"
[ -n "$ps_main" ] || fail "poc.ps1 must define Invoke-Main"
ps_main_flat="$(printf '%s' "$ps_main" | tr '\r\n' '  ')"

for command in $COMMANDS; do
  printf '%s\n' "$bash_dispatch" | grep -Eq "^[[:space:]]*$command\)[[:space:]]*cmd_$command[[:space:]]*;;" || fail "poc.sh must dispatch $command to cmd_$command"
  [ -n "$(bash_function_body "cmd_$command")" ] || fail "poc.sh must define cmd_$command()"
  case "$command" in
    init) ps_command=Init ;;
    build) ps_command=Build ;;
    start) ps_command=Start ;;
    status) ps_command=Status ;;
    doctor) ps_command=Doctor ;;
    smoke) ps_command=Smoke ;;
    logs) ps_command=Logs ;;
    stop) ps_command=Stop ;;
    destroy) ps_command=Destroy ;;
  esac
  printf '%s\n' "$ps_main_flat" | grep -Eqi "['\"]$command['\"][[:space:]]*\{[[:space:]]*Invoke-Poc$ps_command[[:space:]]*\}" || fail "poc.ps1 must dispatch $command to Invoke-Poc$ps_command"
  [ -n "$(ps_function_body "Invoke-Poc$ps_command")" ] || fail "poc.ps1 must define Invoke-Poc$ps_command"
done

[ -n "$(bash_function_body docker_readonly)" ] || fail "poc.sh must define docker_readonly with a verb allowlist"
[ -n "$(ps_function_body Invoke-PocDockerReadOnly)" ] || fail "poc.ps1 must define Invoke-PocDockerReadOnly with a verb allowlist"
[ -n "$(bash_function_body compose)" ] || fail "poc.sh must define a compose helper"
[ -n "$(ps_function_body Invoke-PocCompose)" ] || fail "poc.ps1 must define Invoke-PocCompose"

# --- Doctor is read-only, including reachable helpers. ---
doctor_seen="|"
validate_bash_doctor() {
  local function_name="$1"
  local block helpers helper docker_call verb
  case "$doctor_seen" in
    *"|$function_name|"*) return ;;
  esac
  doctor_seen="${doctor_seen}${function_name}|"
  block="$(bash_function_body "$function_name" | sed 's/[[:space:]]*#.*$//')"
  [ -n "$block" ] || fail "poc.sh doctor helper $function_name must exist"
  printf '%s\n' "$block" | grep -Eqi '(^|[^[:alnum:]_-])(docker[[:space:]]+compose|docker-compose)([[:space:]]|$)' && fail "poc.sh doctor helper $function_name must not invoke Compose"
  if [ "$function_name" = compose ]; then
    fail "poc.sh doctor must not reach the compose helper"
  fi
  printf '%s\n' "$block" | grep -Eqi 'docker\.exe|\$DOCKER|\$\{DOCKER|&[[:space:]]*\$|rm[[:space:]]+-|systemctl|[[:space:]]kill[[:space:]]' && fail "poc.sh doctor helper $function_name uses a forbidden Docker or mutating command"
  if [ "$function_name" = docker_readonly ]; then
    printf '%s\n' "$block" | grep -Eq 'docker[[:space:]]+' || fail "docker_readonly must invoke docker"
    while IFS= read -r docker_call || [ -n "$docker_call" ]; do
      [ -n "$docker_call" ] || continue
      verb="${docker_call#docker }"
      case "$verb" in
        port|logs|inspect|'"$@"'|'$@') ;;
        *) fail "docker_readonly may only invoke docker port, logs, inspect, or \"\$@\"" ;;
      esac
    done <<EOF
$(printf '%s\n' "$block" | grep -Eo 'docker[[:space:]]+[^[:space:];|]+' || true)
EOF
  else
    printf '%s\n' "$block" | grep -Eq '(^|[^[:alnum:]_-])docker[[:space:]]+' && fail "poc.sh doctor helper $function_name must call docker_readonly, not docker"
  fi
  helpers="$(list_bash_functions)"
  while IFS= read -r helper || [ -n "$helper" ]; do
    [ -n "$helper" ] || continue
    [ "$helper" = "$function_name" ] && continue
    printf '%s\n' "$block" | grep -Eq "(^|[^[:alnum:]_-])$helper([[:space:];|()]|$)" || continue
    validate_bash_doctor "$helper"
  done <<EOF
$helpers
EOF
}
validate_bash_doctor cmd_doctor

ps_doctor_seen="|"
validate_ps_doctor() {
  local function_name="$1"
  local block helpers helper
  case "$ps_doctor_seen" in
    *"|$function_name|"*) return ;;
  esac
  ps_doctor_seen="${ps_doctor_seen}${function_name}|"
  block="$(ps_function_body "$function_name" | sed 's/[[:space:]]*#.*$//')"
  [ -n "$block" ] || fail "poc.ps1 doctor helper $function_name must exist"
  printf '%s\n' "$block" | grep -Eqi 'Invoke-PocCompose' && fail "poc.ps1 doctor helper $function_name must not invoke Invoke-PocCompose"
  printf '%s\n' "$block" | grep -Eqi 'docker\.exe|\$DOCKER|\$\{DOCKER|Invoke-Expression|Remove-Item|Set-Content|Add-Content|New-Item|Copy-Item|Move-Item|Start-Process|Stop-Process|Start-Service|Stop-Service|Restart-Service' && fail "poc.ps1 doctor helper $function_name uses a forbidden mutating or variable Docker command"
  if [ "$function_name" = Invoke-PocDockerReadOnly ]; then
    printf '%s\n' "$block" | grep -Eqi 'port|logs|inspect' || fail "Invoke-PocDockerReadOnly must allow only port, logs, and inspect"
  else
    printf '%s\n' "$block" | grep -Eqi '(^|[^[:alnum:]_-])docker([[:space:].]|$)' && fail "poc.ps1 doctor helper $function_name must call Invoke-PocDockerReadOnly, not docker"
    printf '%s\n' "$block" | grep -Eqi 'Invoke-Native[[:space:]]+docker' && fail "poc.ps1 doctor helper $function_name must not call Invoke-Native docker directly"
  fi
  helpers="$(list_ps_functions)"
  while IFS= read -r helper || [ -n "$helper" ]; do
    [ -n "$helper" ] || continue
    [ "$helper" = "$function_name" ] && continue
    printf '%s\n' "$block" | grep -Eqi "(^|[^[:alnum:]_-])$helper([[:space:];|()]|$)" || continue
    validate_ps_doctor "$helper"
  done <<EOF
$helpers
EOF
}
validate_ps_doctor Invoke-PocDoctor

# --- Destroy stays inside the fixed POC Compose project, including helpers. ---
destroy_seen="|"
validate_bash_destroy() {
  local function_name="$1"
  local block helpers helper
  case "$destroy_seen" in
    *"|$function_name|"*) return ;;
  esac
  destroy_seen="${destroy_seen}${function_name}|"
  block="$(bash_function_body "$function_name" | sed 's/[[:space:]]*#.*$//')"
  [ -n "$block" ] || fail "poc.sh destroy helper $function_name must exist"
  if [ "$function_name" = compose ]; then
    printf '%s\n' "$block" | grep -Eq -- '-f[[:space:]]+"?\$\{?COMPOSE_FILE' || fail "compose helper must pass the POC compose file"
    printf '%s\n' "$block" | grep -Eq -- '(-p|--project-name)[[:space:]]+"?\$\{?PROJECT_NAME' || fail "compose helper must pass the fixed POC project name"
    printf '%s\n' "$block" | grep -Eqi -- '--volumes|rmi|[[:space:]]rm[[:space:]]' && fail "compose helper must not delete volumes, images, or files"
  elif [ "$function_name" = cmd_destroy ]; then
    printf '%s\n' "$block" | grep -Eq '^[[:space:]]*compose[[:space:]]+down[[:space:]]+--remove-orphans[[:space:]]*$' || fail "poc.sh destroy must run compose down --remove-orphans"
    printf '%s\n' "$block" | grep -Eqi -- '--volumes|rmi|[[:space:]]rm[[:space:]]|docker[[:space:]]+|systemctl|[[:space:]]kill[[:space:]]' && fail "cmd_destroy must not delete files or call docker directly"
  else
    printf '%s\n' "$block" | grep -Eqi -- '--volumes|rmi|[[:space:]]rm[[:space:]]|docker[[:space:]]+|docker\.exe|Remove-Item|systemctl|[[:space:]]kill[[:space:]]' && fail "poc.sh destroy helper $function_name must not delete volumes, networks, images, or files"
  fi
  helpers="$(list_bash_functions)"
  while IFS= read -r helper || [ -n "$helper" ]; do
    [ -n "$helper" ] || continue
    [ "$helper" = "$function_name" ] && continue
    printf '%s\n' "$block" | grep -Eq "(^|[^[:alnum:]_-])$helper([[:space:];|()]|$)" || continue
    validate_bash_destroy "$helper"
  done <<EOF
$helpers
EOF
}
validate_bash_destroy cmd_destroy

ps_destroy_seen="|"
validate_ps_destroy() {
  local function_name="$1"
  local block helpers helper
  case "$ps_destroy_seen" in
    *"|$function_name|"*) return ;;
  esac
  ps_destroy_seen="${ps_destroy_seen}${function_name}|"
  block="$(ps_function_body "$function_name" | sed 's/[[:space:]]*#.*$//')"
  [ -n "$block" ] || fail "poc.ps1 destroy helper $function_name must exist"
  if [ "$function_name" = Invoke-PocCompose ]; then
    printf '%s\n' "$block" | grep -Eqi -- '-f[[:space:]]+\$script:ComposeFile|--file[[:space:]]+\$script:ComposeFile' || fail "Invoke-PocCompose must pass the POC compose file"
    printf '%s\n' "$block" | grep -Eqi -- '(-p|--project-name)[[:space:]]+\$script:ProjectName' || fail "Invoke-PocCompose must pass the fixed POC project name"
    printf '%s\n' "$block" | grep -Eqi -- '--volumes|rmi|Remove-Item' && fail "Invoke-PocCompose must not delete volumes, images, or files"
  elif [ "$function_name" = Invoke-PocDestroy ]; then
    printf '%s\n' "$block" | grep -Eq "^[[:space:]]*Invoke-PocCompose[[:space:]]+@\(['\"]down['\"][[:space:]]*,[[:space:]]*['\"]--remove-orphans['\"]\)[[:space:]]*$" || fail "poc.ps1 destroy must run Invoke-PocCompose down --remove-orphans"
    printf '%s\n' "$block" | grep -Eqi -- '--volumes|rmi|Remove-Item|docker[[:space:]]+|docker\.exe' && fail "Invoke-PocDestroy must not delete files or call docker directly"
  else
    printf '%s\n' "$block" | grep -Eqi -- '--volumes|rmi|Remove-Item|docker[[:space:]]+|docker\.exe|Stop-Process|Stop-Service' && fail "poc.ps1 destroy helper $function_name must not delete volumes, networks, images, or files"
  fi
  helpers="$(list_ps_functions)"
  while IFS= read -r helper || [ -n "$helper" ]; do
    [ -n "$helper" ] || continue
    [ "$helper" = "$function_name" ] && continue
    printf '%s\n' "$block" | grep -Eqi "(^|[^[:alnum:]_-])$helper([[:space:];|()]|$)" || continue
    validate_ps_destroy "$helper"
  done <<EOF
$helpers
EOF
}
validate_ps_destroy Invoke-PocDestroy

# --- Mocked Docker proves pins, doctor verbs, dispatch, and destroy scope. ---
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MOCK_BIN="$TMP_DIR/mock-bin"
WORKDIR="$TMP_DIR/poc"
mkdir -p "$MOCK_BIN" "$WORKDIR"
cp "$COMPOSE_FILE" "$ENV_EXAMPLE" "$POC_SH" "$POC_PS1" "$WORKDIR/"
cat > "$WORKDIR/poc.env" <<'EOF'
CURSOR_BRIDGE_POC_PORT=18765
CURSOR_API_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CURSOR_BRIDGE_API_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
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
EOF

cat > "$TMP_DIR/docker_mock.py" <<'PY'
import os
import sys

log_path = os.environ["MOCK_DOCKER_LOG"]
with open(log_path, "a", encoding="utf-8") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")

args = sys.argv[1:]
if not args:
    sys.exit(1)
if args[0] == "port":
    print("127.0.0.1:18765")
    sys.exit(0)
if args[0] == "logs":
    print("cursor-bridge ready")
    sys.exit(0)
if args[0] == "image" and "inspect" in args:
    print("sha256:test-image-id")
    sys.exit(0)
if args[0] == "inspect":
    if any(arg == "--format" or arg.startswith("--format=") for arg in args):
        print('app 2147483648 128 ["no-new-privileges:true"] ["ALL"]')
    else:
        print('[{"Config":{"User":"app"},"HostConfig":{"Memory":2147483648,"PidsLimit":128,"SecurityOpt":["no-new-privileges:true"],"CapDrop":["ALL"]}}]')
    sys.exit(0)
sys.exit(0)
PY

cat > "$MOCK_BIN/docker" <<EOF
#!/usr/bin/env bash
exec "$PYTHON" "$TMP_DIR/docker_mock.py" "\$@"
EOF
chmod +x "$MOCK_BIN/docker"

cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *'%{http_code}'* ]]; then
  printf '401'
  exit 0
fi
if [[ "$args" == *healthz* ]]; then
  printf 'ok'
  exit 0
fi
if [[ "$args" == */health* ]]; then
  printf '%s' '{"ok":true,"mode":"ask","force":false,"approveMcps":false}'
  exit 0
fi
if [[ "$args" == *models* ]]; then
  printf '%s' '{"object":"list","data":[{"id":"test-model"}]}'
  exit 0
fi
if [[ "$args" == *chat/completions* ]]; then
  printf '%s\n' 'data: {"choices":[{"delta":{"content":"STREAM_OK"}}]}'
  printf '%s' '{"choices":[{"message":{"content":"CURSOR_POC_OK"}}]}'
  exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/curl"

cat > "$MOCK_BIN/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *'.data[0].id'* ]]; then
  printf 'test-model\n'
  exit 0
fi
if [[ "$args" == *-nc* ]]; then
  printf '{}\n'
  exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/jq"

run_poc() {
  local command_name="$1"
  local log_file="$2"
  : > "$log_file"
  PATH="$MOCK_BIN:$PATH" MOCK_DOCKER_LOG="$log_file" bash "$WORKDIR/poc.sh" "$command_name"
}

assert_log_has() {
  log_file="$1"
  needle="$2"
  message="$3"
  grep -Fq -- "$needle" "$log_file" || fail "$message"
}

assert_log_not() {
  log_file="$1"
  needle="$2"
  message="$3"
  if grep -Fq -- "$needle" "$log_file"; then
    fail "$message"
  fi
}

BUILD_LOG="$TMP_DIR/build.docker.log"
run_poc build "$BUILD_LOG" || fail "mocked poc.sh build must succeed"
assert_log_has "$BUILD_LOG" "buildx build" "mocked build must run docker buildx build"
assert_log_has "$BUILD_LOG" "--load" "mocked build must pass --load"
export BUILD_CONTRACT_LOG="$BUILD_LOG"
export BUILD_CONTRACT_CONTEXT="${SOURCE_REPOSITORY}.git#${SOURCE_COMMIT}"
export BUILD_CONTRACT_IMAGE="$EXPECTED_IMAGE"
export BUILD_CONTRACT_REVISION="$SOURCE_COMMIT"
"$PYTHON" -c '
import os, sys

def fail(message):
    sys.stderr.write("FAIL: %s\n" % message)
    sys.exit(1)

no_value = set(("--load", "--push", "--pull", "--no-cache", "--quiet", "-q", "--rm"))
lines = open(os.environ["BUILD_CONTRACT_LOG"], encoding="utf-8").read().splitlines()
build_lines = [line for line in lines if "buildx" in line]
if not build_lines:
    fail("mocked build must run docker buildx")
tokens = build_lines[0].split()
context = os.environ["BUILD_CONTRACT_CONTEXT"]
image = os.environ["BUILD_CONTRACT_IMAGE"]
revision = os.environ["BUILD_CONTRACT_REVISION"]
positional = []
tag = None
revision_label = False
i = 0
while i < len(tokens):
    token = tokens[i]
    if token in ("buildx", "build") or token in no_value:
        i += 1
        continue
    if token in ("-t", "--tag") and i + 1 < len(tokens):
        tag = tokens[i + 1]
        i += 2
        continue
    if token.startswith("--tag="):
        tag = token.split("=", 1)[1]
        i += 1
        continue
    if token == "--label" and i + 1 < len(tokens):
        value = tokens[i + 1]
        if value == "org.opencontainers.image.revision=" + revision:
            revision_label = True
        i += 2
        continue
    if token.startswith("--label="):
        if token.split("=", 1)[1] == "org.opencontainers.image.revision=" + revision:
            revision_label = True
        i += 1
        continue
    if token.startswith("-") and i + 1 < len(tokens) and not tokens[i + 1].startswith("-"):
        i += 2
        continue
    if token.startswith("-"):
        i += 1
        continue
    positional.append(token)
    i += 1
if not positional or positional[-1] != context:
    fail("mocked build context must be the final positional argument %s" % context)
if tag != image:
    fail("mocked build -t/--tag must be %s" % image)
if not revision_label:
    fail("mocked build must label org.opencontainers.image.revision with the pinned commit")
'

DOCTOR_LOG="$TMP_DIR/doctor.docker.log"
run_poc doctor "$DOCTOR_LOG" || fail "mocked poc.sh doctor must succeed"
[ -s "$DOCTOR_LOG" ] || fail "mocked doctor must invoke docker port, logs, or inspect"
if grep -Eqi 'compose|buildx|run|rm|pull|stop|kill|volume|network|system' "$DOCTOR_LOG"; then
  fail "mocked doctor invoked a Docker verb outside port/logs/inspect"
fi
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  verb="${line%% *}"
  case "$verb" in
    port|logs|inspect) ;;
    *) fail "mocked doctor Docker verb is not read-only: $line" ;;
  esac
done < "$DOCTOR_LOG"

DESTROY_LOG="$TMP_DIR/destroy.docker.log"
find "$WORKDIR" | sort > "$TMP_DIR/destroy-before"
run_poc destroy "$DESTROY_LOG" || fail "mocked poc.sh destroy must succeed"
find "$WORKDIR" | sort > "$TMP_DIR/destroy-after"
cmp -s "$TMP_DIR/destroy-before" "$TMP_DIR/destroy-after" || fail "destroy must not add or delete files in the POC directory"
assert_log_has "$DESTROY_LOG" "compose" "mocked destroy must call docker compose"
assert_log_has "$DESTROY_LOG" "down --remove-orphans" "mocked destroy must pass down --remove-orphans"
if ! grep -Fq -- "-p $PROJECT_NAME" "$DESTROY_LOG" && ! grep -Fq -- "--project-name $PROJECT_NAME" "$DESTROY_LOG"; then
  fail "mocked destroy must target project $PROJECT_NAME via -p or --project-name"
fi
assert_log_not "$DESTROY_LOG" "--volumes" "mocked destroy must not delete volumes"
assert_log_not "$DESTROY_LOG" "rmi" "mocked destroy must not delete images"
assert_log_not "$DESTROY_LOG" "volume" "mocked destroy must not delete Docker volumes"
assert_log_not "$DESTROY_LOG" "network" "mocked destroy must not delete networks"
[ "$(grep -c . "$DESTROY_LOG" || true)" -eq 1 ] || fail "mocked destroy must make exactly one Docker invocation"

for command in start status logs stop smoke; do
  cmd_log="$TMP_DIR/${command}.docker.log"
  run_poc "$command" "$cmd_log" || fail "mocked poc.sh $command must dispatch successfully"
done

if PATH="$MOCK_BIN:$PATH" MOCK_DOCKER_LOG="$TMP_DIR/unknown.docker.log" bash "$WORKDIR/poc.sh" not-a-command; then
  fail "poc.sh must reject unknown commands"
fi

printf 'PASS: Cursor Bridge POC static contract is isolated and hardened\n'
