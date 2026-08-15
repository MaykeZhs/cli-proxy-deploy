#!/usr/bin/env bash
# Cursor Bridge sidecar static contract: CPA talks to cursor-bridge:8765.
# Bash 3.2 compatible.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.cursor-bridge.yml"
ENV_EXAMPLE="$ROOT_DIR/cursor-bridge.env.example"
GITIGNORE="$ROOT_DIR/.gitignore"
SECURITY="$ROOT_DIR/SECURITY.md"
SOURCE_COMMIT="c0ff1f941215027c0a8f658ca5d01f806559208f"
SOURCE_REPOSITORY="https://github.com/anyrobert/cursor-api-proxy"
EXPECTED_IMAGE="cursor-api-proxy:poc-$SOURCE_COMMIT"
PROJECT_NAME="cursor-bridge"

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

for rel in \
  docker-compose.cursor-bridge.yml \
  cursor-bridge.env.example \
  docs/cursor-bridge.md
do
  [ -f "$ROOT_DIR/$rel" ] || fail "Missing required sidecar file: $rel"
done
[ -e "$ROOT_DIR/cursor-bridge/nginx-guard.conf" ] && fail "nginx-guard.conf must be removed for direct CPA to :8765"

contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
not_contains() { ! grep -Fq -- "$2" "$1" || fail "$3"; }
strip_cr() { tr -d '\r' < "$1"; }

image_lines="$(strip_cr "$COMPOSE_FILE" | grep -E '^[[:space:]]*image:[[:space:]]*' || true)"
printf '%s\n' "$image_lines" | grep -Fq "$EXPECTED_IMAGE" || fail "Compose must pin $EXPECTED_IMAGE"
image_count="$(printf '%s\n' "$image_lines" | grep -c . || true)"
[ "$image_count" -eq 1 ] || fail "Compose must define exactly one image: line"

bridge_image_line="$(printf '%s\n' "$image_lines" | grep -F "$EXPECTED_IMAGE" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
[ "$bridge_image_line" = "image: $EXPECTED_IMAGE" ] || fail "Bridge image must be hard-coded as $EXPECTED_IMAGE"
printf '%s\n' "$bridge_image_line" | grep -Fq '$' && fail "Bridge image must not use a variable"

not_contains "$COMPOSE_FILE" 'CURSOR_BRIDGE_POC_IMAGE' "Compose must not accept a CURSOR_BRIDGE_POC_IMAGE override"
not_contains "$COMPOSE_FILE" 'latest' "Compose must not use a latest tag"
not_contains "$COMPOSE_FILE" '0.0.0.0:' "Compose must not publish 0.0.0.0 host ports"
not_contains "$COMPOSE_FILE" '18765' "Compose must not publish 18765"
not_contains "$COMPOSE_FILE" '${CURSOR_API_KEY' "Compose must not interpolate CURSOR_API_KEY from .env"
not_contains "$COMPOSE_FILE" '${CURSOR_BRIDGE_API_KEY' "Compose must not interpolate CURSOR_BRIDGE_API_KEY from .env"
not_contains "$COMPOSE_FILE" 'CPA_API_KEY' "Compose must not reference CPA_API_KEY"
not_contains "$COMPOSE_FILE" 'CPA_MANAGEMENT_KEY' "Compose must not reference CPA_MANAGEMENT_KEY"
not_contains "$COMPOSE_FILE" 'CURSOR_CONFIG_DIRS' "Compose must not set CURSOR_CONFIG_DIRS"
not_contains "$COMPOSE_FILE" 'CURSOR_ACCOUNT_DIRS' "Compose must not set CURSOR_ACCOUNT_DIRS"
not_contains "$COMPOSE_FILE" 'internal: true' "Networks must not be internal: true"
not_contains "$COMPOSE_FILE" 'internal:true' "Networks must not be internal:true"
not_contains "$COMPOSE_FILE" 'cursor-bridge-guard' "Compose must not define a guard service"
not_contains "$COMPOSE_FILE" 'cursor-bridge-backend' "Compose must not keep the old backend-only network"
not_contains "$COMPOSE_FILE" 'nginx' "Compose must not use nginx"
contains "$COMPOSE_FILE" 'pull_policy: never' "Bridge must set pull_policy: never"
contains "$COMPOSE_FILE" 'user: app' "Bridge must run as user app"
contains "$COMPOSE_FILE" 'name: cpa-cursor-bridge' "Must create named network cpa-cursor-bridge"
contains "$COMPOSE_FILE" "$SOURCE_COMMIT" "Compose must record the pinned commit"
contains "$COMPOSE_FILE" "$SOURCE_REPOSITORY" "Compose must record the upstream repository"

if grep -Eq '^[[:space:]]*ports:' "$COMPOSE_FILE"; then
  fail "Sidecar compose must not declare ports:"
fi

env_effective="$(strip_cr "$ENV_EXAMPLE" | sed -E '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/[[:space:]]*#.*$//')"
printf '%s\n' "$env_effective" | grep -Fq 'CURSOR_API_KEY=' || fail "Environment example must define CURSOR_API_KEY"
printf '%s\n' "$env_effective" | grep -Fq 'CURSOR_BRIDGE_API_KEY=' || fail "Environment example must define CURSOR_BRIDGE_API_KEY"
printf '%s\n' "$env_effective" | grep -Fq 'CURSOR_CONFIG_DIRS=' && fail "Environment example must not define CURSOR_CONFIG_DIRS"
printf '%s\n' "$env_effective" | grep -Fq 'CURSOR_ACCOUNT_DIRS=' && fail "Environment example must not define CURSOR_ACCOUNT_DIRS"
not_contains "$ENV_EXAMPLE" 'latest' "Environment example must not use a latest tag"
not_contains "$ENV_EXAMPLE" 'CURSOR_BRIDGE_POC_IMAGE' "Environment example must not define CURSOR_BRIDGE_POC_IMAGE"
not_contains "$ENV_EXAMPLE" 'CPA_API_KEY=' "Environment example must not set CPA_API_KEY"

contains "$GITIGNORE" 'cursor-bridge.env' ".gitignore must ignore cursor-bridge.env"
contains "$SECURITY" 'cursor-bridge.env' "SECURITY.md must mention cursor-bridge.env"
contains "$SECURITY" 'cursor-bridge:8765' "SECURITY.md must describe the direct CPA to :8765 path"
not_contains "$SECURITY" 'cursor-bridge-guard' "SECURITY.md must not require the removed guard"

require_python
docker compose version >/dev/null 2>&1 || fail "docker compose is required to validate the sidecar stack"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp "$COMPOSE_FILE" "$TMP_DIR/docker-compose.cursor-bridge.yml"
cp "$ENV_EXAMPLE" "$TMP_DIR/cursor-bridge.env"

COMPOSE_JSON="$(
  docker compose --project-directory "$TMP_DIR" \
    -f "$TMP_DIR/docker-compose.cursor-bridge.yml" \
    config --format json
)" || fail "docker compose config --format json failed"

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
names = sorted(services.keys())
if names != ["cursor-bridge"]:
    fail("Compose must define exactly cursor-bridge, got %s" % names)

bridge = services["cursor-bridge"]

if bridge.get("image") != expected_image:
    fail("Effective bridge image must be %s" % expected_image)
if bridge.get("build"):
    fail("Compose must not declare a build section on the bridge")
if bridge.get("pull_policy") != "never":
    fail("pull_policy must be never")
if bridge.get("ports"):
    fail("cursor-bridge must not publish host ports")
if bridge.get("expose"):
    fail("cursor-bridge must not declare expose")
if bridge.get("privileged") is True:
    fail("privileged must not be enabled")
if bridge.get("network_mode") == "host":
    fail("network_mode must not be host")

for key in ("volumes", "volumes_from", "devices", "configs", "secrets"):
    value = bridge.get(key)
    if value:
        fail("cursor-bridge must not define %s" % key)

if list(bridge.get("cap_drop") or []) != ["ALL"]:
    fail("bridge cap_drop must be ALL")
if "no-new-privileges:true" not in list(bridge.get("security_opt") or []):
    fail("bridge security_opt must include no-new-privileges:true")
if bridge.get("pids_limit") != 128:
    fail("bridge pids_limit must be 128")
if int(bridge.get("mem_limit") or 0) != 2147483648:
    fail("bridge memory must be 2 GiB")
if bridge.get("cpus") not in (2, 2.0):
    fail("bridge CPUs must be 2")
if bridge.get("init") is not True:
    fail("bridge init must be true")
if str(bridge.get("user") or "") != "app":
    fail("bridge user must be app")

env = bridge.get("environment")
if not isinstance(env, dict):
    fail("Bridge must use an explicit environment map")

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
    "CURSOR_BRIDGE_TIMEOUT_MS": "300000",
}
for key, value in required.items():
    if str(env.get(key)) != value:
        fail("effective environment %s must be %s" % (key, value))
for key in ("CURSOR_CONFIG_DIRS", "CURSOR_ACCOUNT_DIRS"):
    if key in env:
        fail("%s must remain unset" % key)

networks = cfg.get("networks") or {}
cpa_net = None
for net in networks.values():
    name = net.get("name") or ""
    if name == "cpa-cursor-bridge":
        cpa_net = net
    if name == "cursor-bridge-backend":
        fail("cursor-bridge-backend must be removed")
if cpa_net is None:
    fail("named network cpa-cursor-bridge is required")
if cpa_net.get("internal") is True:
    fail("sidecar network must not be internal")

bridge_nets = set((bridge.get("networks") or {}).keys()) if isinstance(bridge.get("networks"), dict) else set(bridge.get("networks") or [])

def net_names(svc_nets, cfg_nets):
    out = set()
    for key in svc_nets:
        net = cfg_nets.get(key) or {}
        out.add(net.get("name") or key)
    return out

bridge_net_names = net_names(bridge_nets, networks)
if "cpa-cursor-bridge" not in bridge_net_names:
    fail("cursor-bridge must join cpa-cursor-bridge so CPA can reach :8765")
'

contains "$ROOT_DIR/deploy.sh" 'docker compose -p "${CURSOR_BRIDGE_PROJECT_NAME}"' "deploy.sh must set the Compose project with -p"
if awk '/^cursor_bridge_compose\(\)/,/^cursor_bridge_env_value\(\)/' "$ROOT_DIR/deploy.sh" | grep -Eq 'COMPOSE_PROJECT_NAME='; then
  fail "cursor_bridge_compose must not assign readonly COMPOSE_PROJECT_NAME"
fi
contains "$ROOT_DIR/deploy.sh" 'http://cursor-bridge:8765/v1' "deploy.sh must point CPA at cursor-bridge:8765"
contains "$ROOT_DIR/deploy.ps1" 'http://cursor-bridge:8765/v1' "deploy.ps1 must point CPA at cursor-bridge:8765"
contains "$ROOT_DIR/deploy.sh" 'cmd_cursor_bridge' "deploy.sh must dispatch cursor-bridge"
contains "$ROOT_DIR/deploy.ps1" 'cmd-cursor-bridge' "deploy.ps1 must dispatch cursor-bridge"
contains "$ROOT_DIR/deploy.sh" 'prompt_cursor_api_key' "deploy.sh must prompt for the Cursor key"
contains "$ROOT_DIR/deploy.sh" 'read -rs key' "deploy.sh must hide Cursor key input"
contains "$ROOT_DIR/deploy.ps1" 'Read-Host -AsSecureString' "deploy.ps1 must hide Cursor key input"
contains "$ROOT_DIR/deploy.sh" 'cmd_cursor_bridge_configure' "deploy.sh must support cursor-bridge configure"
contains "$ROOT_DIR/deploy.ps1" 'cmd-cursor-bridge-configure' "deploy.ps1 must support cursor-bridge configure"
contains "$ROOT_DIR/deploy.sh" "CURSOR_BRIDGE_IMAGE=\"$EXPECTED_IMAGE\"" "deploy.sh must pin CURSOR_BRIDGE_IMAGE"
contains "$ROOT_DIR/deploy.ps1" "CURSOR_BRIDGE_IMAGE            = '$EXPECTED_IMAGE'" "deploy.ps1 must pin CURSOR_BRIDGE_IMAGE"
grep -Eq '^[[:space:]]*""[[:space:]]*\)[[:space:]]*cmd_deploy' "$ROOT_DIR/deploy.sh" || fail "deploy.sh default wizard must stay cmd_deploy"
grep -Eq "start\)[[:space:]]*cmd_start" "$ROOT_DIR/deploy.sh" || fail "deploy.sh start must stay cmd_start"
grep -Eq "''[[:space:]]*\{[[:space:]]*cmd-deploy" "$ROOT_DIR/deploy.ps1" || fail "deploy.ps1 default wizard must stay cmd-deploy"
if awk '/^cmd_cursor_bridge_uninstall\(\)/,/^cmd_cursor_bridge\(\)/' "$ROOT_DIR/deploy.sh" | grep -Fq -- '--volumes'; then
  fail "cursor-bridge uninstall must not use --volumes"
fi
if awk '/function cmd-cursor-bridge-uninstall/,/function show-cursor-bridge-help/' "$ROOT_DIR/deploy.ps1" | grep -Fq -- '--volumes'; then
  fail "ps1 cursor-bridge uninstall must not use --volumes"
fi

printf 'PASS: Cursor Bridge sidecar static contract is isolated and hardened\n'
