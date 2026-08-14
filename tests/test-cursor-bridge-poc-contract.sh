#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POC_DIR="$ROOT_DIR/poc/cursor-bridge"
COMPOSE_FILE="$POC_DIR/docker-compose.yml"
ENV_EXAMPLE="$POC_DIR/poc.env.example"
POC_SH="$POC_DIR/poc.sh"
POC_PS1="$POC_DIR/poc.ps1"
SOURCE_COMMIT="c0ff1f941215027c0a8f658ca5d01f806559208f"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
not_contains() { ! grep -Fq -- "$2" "$1" || fail "$3"; }
contains_text() { [[ "$1" == *"$2"* ]] || fail "$3"; }
not_contains_text() { [[ "$1" != *"$2"* ]] || fail "$3"; }

bash_function_body() {
  awk -v name="$1" '
    $0 ~ "^[[:space:]]*" name "[[:space:]]*\\(\\)" { active = 1 }
    active && $0 !~ "^[[:space:]]*" name "[[:space:]]*\\(\\)" && $0 ~ "^[[:space:]]*[[:alpha:]_][[:alnum:]_]*[[:space:]]*\\(\\)" { exit }
    active { print }
  ' "$POC_SH"
}

ps_function_body() {
  awk -v name="$1" '
    /^[[:space:]]*function[[:space:]]+/ {
      line = $0; sub(/^[[:space:]]*/, "", line); split(line, parts, /[[:space:]]+/)
      if (active && tolower(parts[2]) != tolower(name)) exit
      if (tolower(parts[2]) == tolower(name)) active = 1
    }
    active { print }
  ' "$POC_PS1"
}

compose_service_body() {
  awk '
    /^[[:space:]]*services:[[:space:]]*$/ { services = 1; next }
    services && /^[[:space:]]{2}cursor-bridge:[[:space:]]*$/ { active = 1; next }
    active && /^[[:space:]]{2}[[:alnum:]_-]+:[[:space:]]*$/ { exit }
    active { sub(/[[:space:]]*#.*/, ""); if ($0 !~ /^[[:space:]]*$/) print }
  ' "$COMPOSE_FILE"
}

for required_file in "$COMPOSE_FILE" "$ENV_EXAMPLE" "$POC_SH" "$POC_PS1"; do
  [[ -f "$required_file" ]] || fail "Missing required POC file: $required_file"
done

COMPOSE_SERVICE="$(compose_service_body)"
[[ -n "$COMPOSE_SERVICE" ]] || fail "Compose must define a cursor-bridge service"

contains "$POC_SH" "$SOURCE_COMMIT" "poc.sh must pin source commit $SOURCE_COMMIT"
contains "$POC_PS1" "$SOURCE_COMMIT" "poc.ps1 must pin source commit $SOURCE_COMMIT"
port_8765_mappings="$(awk '
  /^[[:space:]]*-/ {
    mapping = $0
    sub(/^[[:space:]]*-[[:space:]]*/, "", mapping)
    sub(/[[:space:]]*#.*/, "", mapping)
    if ((mapping ~ /^"/ && mapping ~ /"[[:space:]]*$/) || (mapping ~ /^\047/ && mapping ~ /\047[[:space:]]*$/)) {
      mapping = substr(mapping, 2, length(mapping) - 2)
    }
    if (mapping ~ /:8765(\/(tcp|udp))?[[:space:]]*$/) print mapping
  }
' <<<"$COMPOSE_SERVICE")"
port_8765_count="$(grep -c . <<<"$port_8765_mappings" || true)"
[[ "$port_8765_count" -eq 1 ]] || fail "Compose must define exactly one short-syntax mapping for container port 8765"
[[ "$port_8765_mappings" == '127.0.0.1:${CURSOR_BRIDGE_POC_PORT:-18765}:8765' ]] || fail "Compose must bind container port 8765 with the exact loopback mapping"
! grep -Eq "^[[:space:]]*(-[[:space:]]*)?target:[[:space:]]*['\"]?8765['\"]?([[:space:]]|#|$)" <<<"$COMPOSE_SERVICE" || fail "Compose must not use long-syntax target: 8765 port mappings"
not_contains_text "$COMPOSE_SERVICE" '0.0.0.0:' "Compose must not expose the POC on all IPv4 interfaces"
not_contains_text "$COMPOSE_SERVICE" ':::' "Compose must not expose the POC on all IPv6 interfaces"
contains_text "$COMPOSE_SERVICE" 'pull_policy: never' "Compose must never pull an unpinned image"
image_lines="$(grep -E '^[[:space:]]*image:[[:space:]]*[^[:space:]]+' <<<"$COMPOSE_SERVICE" || true)"
[[ "$(grep -c . <<<"$image_lines" || true)" -eq 1 ]] || fail "Compose must define exactly one cursor-bridge image"
image_ref="$(sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]+$//' <<<"$image_lines")"
image_ref="${image_ref#\"}"; image_ref="${image_ref%\"}"
image_ref="${image_ref#\'}"; image_ref="${image_ref%\'}"
image_basename="${image_ref##*/}"
[[ "$image_ref" == *@sha256:* || "$image_basename" == *:* && "${image_basename##*:}" != "$image_basename" ]] || fail "Compose image must use an explicit immutable tag or digest"
[[ "$image_ref" != *:latest ]] || fail "Compose image must not use the mutable latest tag"
ENV_EFFECTIVE="$(sed -E '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/[[:space:]]*#.*$//' "$ENV_EXAMPLE")"
env_image_lines="$(grep -E '^[[:space:]]*CURSOR_BRIDGE_IMAGE=' <<<"$ENV_EFFECTIVE" || true)"
if [[ -n "$env_image_lines" ]]; then
  [[ "$(grep -c . <<<"$env_image_lines")" -eq 1 ]] || fail "Environment example must not define duplicate CURSOR_BRIDGE_IMAGE values"
  env_image_ref="${env_image_lines#*=}"
  env_image_ref="${env_image_ref#\"}"; env_image_ref="${env_image_ref%\"}"
  env_image_ref="${env_image_ref#\'}"; env_image_ref="${env_image_ref%\'}"
  env_image_basename="${env_image_ref##*/}"
  [[ "$env_image_ref" == *@sha256:* || "$env_image_basename" == *:* && "${env_image_basename##*:}" != "$env_image_basename" ]] || fail "CURSOR_BRIDGE_IMAGE must use an explicit tag or digest"
  [[ "$env_image_ref" != *:latest ]] || fail "CURSOR_BRIDGE_IMAGE must not use the mutable latest tag"
fi

contains_text "$COMPOSE_SERVICE" 'cap_drop:' "Compose must drop Linux capabilities"
contains_text "$COMPOSE_SERVICE" '      - ALL' "Compose must drop all Linux capabilities"
contains_text "$COMPOSE_SERVICE" 'no-new-privileges:true' "Compose must enable no-new-privileges"
contains_text "$COMPOSE_SERVICE" 'pids_limit: 128' "Compose must limit PIDs"
contains_text "$COMPOSE_SERVICE" 'mem_limit: 2g' "Compose must limit memory"
contains_text "$COMPOSE_SERVICE" 'cpus: "2.0"' "Compose must limit CPU"
for forbidden_mount in /var/run/docker.sock /run/docker.sock /root/.cli-proxy-api cli-proxy-manager-auth ../config.yaml ./config.yaml /config.yaml; do
  not_contains_text "$COMPOSE_SERVICE" "$forbidden_mount" "Compose must not mount live Docker or CPA configuration: $forbidden_mount"
done

for setting in CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true CURSOR_BRIDGE_MODE=ask CURSOR_BRIDGE_FORCE=false CURSOR_BRIDGE_APPROVE_MCPS=false CURSOR_BRIDGE_VERBOSE=false CURSOR_BRIDGE_MAX_MODE=false CURSOR_BRIDGE_USE_ACP=true CURSOR_BRIDGE_ACP_RAW_DEBUG=false CURSOR_BRIDGE_MULTI_PORT=false; do
  setting_name="${setting%%=*}"
  setting_value="${setting#*=}"
  setting_lines="$(grep -E "^[[:space:]]*$setting_name=" "$ENV_EXAMPLE" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]+$//' || true)"
  [[ "$(grep -c . <<<"$setting_lines" || true)" -eq 1 && "$setting_lines" == "$setting_name=$setting_value" ]] || fail "Environment example must define exactly one safe $setting"
done
not_contains_text "$ENV_EFFECTIVE" 'CURSOR_CONFIG_DIRS=' "Environment example must not define CURSOR_CONFIG_DIRS"
not_contains_text "$ENV_EFFECTIVE" 'CURSOR_ACCOUNT_DIRS=' "Environment example must not define CURSOR_ACCOUNT_DIRS"

for command in init build start status doctor smoke logs stop destroy; do
  grep -Eq "^[[:space:]]*$command\)[[:space:]]*cmd_$command[[:space:]]*;;" "$POC_SH" || fail "poc.sh must dispatch $command to cmd_$command"
  [[ -n "$(bash_function_body "cmd_$command")" ]] || fail "poc.sh must define cmd_$command()"
  ps_command="${command^}"
  grep -Eq "^[[:space:]]*['\"]?$command['\"]?[[:space:]]*\{[[:space:]]*Invoke-Poc$ps_command[[:space:]]*\}" "$POC_PS1" || fail "poc.ps1 must dispatch $command to Invoke-Poc$ps_command"
  [[ -n "$(ps_function_body "Invoke-Poc$ps_command")" ]] || fail "poc.ps1 must define Invoke-Poc$ps_command"
done

bash_build_block="$(bash_function_body cmd_build)"
contains_text "$bash_build_block" 'SOURCE_COMMIT' "poc.sh build must use SOURCE_COMMIT"
grep -Eqi 'git[[:space:]].*(checkout|reset)[[:space:]].*(SOURCE_COMMIT|c0ff1f941215027c0a8f658ca5d01f806559208f)' <<<"$bash_build_block" || fail "poc.sh build must check out the pinned source commit"
ps_build_block="$(ps_function_body Invoke-PocBuild)"
contains_text "$ps_build_block" 'SourceCommit' "poc.ps1 build must use SourceCommit"
grep -Eqi 'git[[:space:]].*(checkout|reset)[[:space:]].*(SourceCommit|c0ff1f941215027c0a8f658ca5d01f806559208f)' <<<"$ps_build_block" || fail "poc.ps1 build must check out the pinned source commit"

grep -Eq '^[[:space:]]*cmd_doctor\(\)' "$POC_SH" || fail "poc.sh must define cmd_doctor()"
grep -Eq '^[[:space:]]*cmd_smoke\(\)' "$POC_SH" || fail "poc.sh must define cmd_smoke() after cmd_doctor()"
doctor_line="$(grep -nE '^[[:space:]]*cmd_doctor\(\)' "$POC_SH" | head -n 1 | cut -d: -f1)"
smoke_line="$(grep -nE '^[[:space:]]*cmd_smoke\(\)' "$POC_SH" | head -n 1 | cut -d: -f1)"
(( doctor_line < smoke_line )) || fail "poc.sh must define cmd_smoke() after cmd_doctor()"
doctor_block="$(sed -n '/^[[:space:]]*cmd_doctor()/,/^[[:space:]]*cmd_smoke()/p' "$POC_SH")"
[[ "$doctor_block" == *'cmd_smoke()'* ]] || fail "poc.sh doctor block must end at cmd_smoke()"
declare -A doctor_seen_functions=()
validate_bash_doctor_reachability() {
  local function_name="$1" block helper docker_call docker_verb
  [[ -z "${doctor_seen_functions[$function_name]+x}" ]] || return
  doctor_seen_functions[$function_name]=1
  block="$(bash_function_body "$function_name" | sed 's/[[:space:]]*#.*$//')"
  if grep -Eqi '(^|[^[:alnum:]_-])(docker[[:space:]]+compose|docker-compose|compose)([[:space:]]|$)' <<<"$block"; then
    fail "poc.sh doctor reachability must not invoke Compose ($function_name)"
  fi
  while IFS= read -r docker_call; do
    [[ -n "$docker_call" ]] || continue
    docker_verb="${docker_call#docker }"
    case "$docker_verb" in
      port|logs|inspect) ;;
      *) fail "poc.sh doctor reachability may only use docker port, docker logs, or docker inspect ($docker_verb)" ;;
    esac
  done < <(grep -Eo 'docker[[:space:]]+[^[:space:];|]+' <<<"$block" || true)
  while IFS= read -r helper; do
    [[ "$helper" == "$function_name" ]] && continue
    if grep -Eq "(^|[^[:alnum:]_-])$helper([[:space:];|()]|$)" <<<"$block"; then
      validate_bash_doctor_reachability "$helper"
    fi
  done < <(awk '/^[[:space:]]*[[:alpha:]_][[:alnum:]_]*[[:space:]]*\(\)/ { sub(/^[[:space:]]*/, ""); sub(/[[:space:]]*\(.*/, ""); print }' "$POC_SH")
}
validate_bash_doctor_reachability cmd_doctor

grep -Eqi '^[[:space:]]*function[[:space:]]+Invoke-PocDoctor\b' "$POC_PS1" || fail "poc.ps1 must define Invoke-PocDoctor"
grep -Eqi '^[[:space:]]*function[[:space:]]+Invoke-PocSmoke\b' "$POC_PS1" || fail "poc.ps1 must define Invoke-PocSmoke after Invoke-PocDoctor"
ps_doctor_block="$(sed -n '/^[[:space:]]*function[[:space:]]\+Invoke-PocDoctor/,/^[[:space:]]*function[[:space:]]\+Invoke-PocSmoke/p' "$POC_PS1")"
[[ "$ps_doctor_block" == *'Invoke-PocSmoke'* ]] || fail "poc.ps1 doctor block must end at Invoke-PocSmoke"
declare -A ps_doctor_seen_functions=()
validate_ps_doctor_reachability() {
  local function_name="$1" block helper docker_call docker_verb
  [[ -z "${ps_doctor_seen_functions[$function_name]+x}" ]] || return
  ps_doctor_seen_functions[$function_name]=1
  block="$(ps_function_body "$function_name" | sed 's/[[:space:]]*#.*$//')"
  if grep -Eqi 'Invoke-PocCompose\b' <<<"$block"; then
    fail "poc.ps1 doctor reachability must not invoke Invoke-PocCompose ($function_name)"
  fi
  while IFS= read -r docker_call; do
    [[ -n "$docker_call" ]] || continue
    docker_verb="${docker_call#docker }"
    case "$docker_verb" in
      port|logs|inspect) ;;
      *) fail "poc.ps1 doctor reachability may only use docker port, docker logs, or docker inspect ($docker_verb)" ;;
    esac
  done < <(grep -Eo 'docker[[:space:]]+[^[:space:];|]+' <<<"$block" || true)
  while IFS= read -r helper; do
    [[ "$helper" == "$function_name" ]] && continue
    if grep -Eqi "(^|[^[:alnum:]_-])$helper([[:space:];|()]|$)" <<<"$block"; then
      validate_ps_doctor_reachability "$helper"
    fi
  done < <(awk '/^[[:space:]]*function[[:space:]]+/ { line = $0; sub(/^[[:space:]]*/, "", line); split(line, parts, /[[:space:]]+/); print parts[2] }' "$POC_PS1")
}
validate_ps_doctor_reachability Invoke-PocDoctor

bash_destroy_block="$(bash_function_body cmd_destroy | sed 's/[[:space:]]*#.*$//')"
contains_text "$bash_destroy_block" 'compose down --remove-orphans' "poc.sh destroy must remove only POC Compose resources"
! grep -Eqi '(docker[[:space:]]+|rm[[:space:]]+-rf|--volumes|volume|system|network)' <<<"$bash_destroy_block" || fail "poc.sh destroy must not delete broader Docker or filesystem resources"
ps_destroy_block="$(sed -n '/^[[:space:]]*function[[:space:]]\+Invoke-PocDestroy/,/^[[:space:]]*function[[:space:]]\+Invoke-Poc[A-Z][a-zA-Z]*/p' "$POC_PS1")"
contains_text "$ps_destroy_block" "Invoke-PocCompose @('down','--remove-orphans')" "poc.ps1 destroy must remove only POC Compose resources"
! grep -Eqi '(docker[[:space:]]+|Remove-Item|--volumes|volume|system|network)' <<<"$ps_destroy_block" || fail "poc.ps1 destroy must not delete broader Docker or filesystem resources"

printf 'PASS: Cursor Bridge POC static contract is isolated and hardened\n'
