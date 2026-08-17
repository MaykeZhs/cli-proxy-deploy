#!/usr/bin/env bash
# =============================================================================
#
#   ╔═══════════════════════════════════════════════════════════════════╗
#   ║   CLI Proxy Manager — One-Click Deployment for CLIProxyAPI      ║
#   ║   部署和管理 CLIProxyAPI，在 Claude Code / Cursor 等工具中使用            ║
#   ╚═══════════════════════════════════════════════════════════════════╝
#
#   用法:  bash deploy.sh          # 交互式完整部署
#          bash deploy.sh login    # 仅 OAuth 登录
#          bash deploy.sh logout   # 退出 Provider 账号
#          bash deploy.sh start    # 仅启动服务
#          bash deploy.sh stop     # 停止服务
#          bash deploy.sh status   # 查看状态
#          bash deploy.sh logs     # 实时日志
#          bash deploy.sh capabilities [--json] # 只读能力检查
#          bash deploy.sh doctor   # 自检诊断
#          bash deploy.sh backup   # 备份配置和凭证
#          bash deploy.sh restore <file> # 恢复配置和凭证
#          bash deploy.sh check-update # 检查镜像更新
#          bash deploy.sh update   # 更新到最新版
#          bash deploy.sh rollback # 回滚到更新前镜像
#          bash deploy.sh auto-update # 有新镜像时才更新（适合 cron）
#          bash deploy.sh enable-auto-update [cron] # 启用每日自动更新
#          bash deploy.sh disable-auto-update # 禁用自动更新
#          bash deploy.sh uninstall # 完全卸载
#          bash deploy.sh setup-claude # 配置 Claude Code
#          bash deploy.sh sub2api deploy # 一键部署 Sub2API
#          bash deploy.sh cursor-bridge start # 启动可选 Cursor Bridge sidecar
#
# =============================================================================

if [ -z "${BASH_VERSION:-}" ] || [[ ":${SHELLOPTS:-}:" == *":posix:"* ]]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

# ========================== 常量 & 默认值 ====================================

readonly VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_IMAGE="${CPA_IMAGE:-eceasy/cli-proxy-api:latest}"
readonly ROLLBACK_IMAGE="eceasy/cli-proxy-api:rollback"
readonly RELEASE_CONTRACT_CPA_VERSION="v7.2.111"
readonly RELEASE_CONTRACT_CPA_COMMIT="4a315136730baa8b3a436d12b74e5a702c70be5c"
readonly RELEASE_CONTRACT_MANAGEMENT_CENTER_VERSION="v1.20.4"
readonly RELEASE_CONTRACT_MANAGEMENT_CENTER_COMMIT="826ea3c0d0bdd6409a0a2703ada90faaf5aede2d"

readonly COMPOSE_PROJECT_NAME="cli-proxy-manager"
export COMPOSE_PROJECT_NAME
readonly CONTAINER_NAME="cli-proxy-manager"
readonly AUTH_VOLUME="cli-proxy-manager-auth"
readonly OAUTH_PORT=51121
readonly CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly SUB2API_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.sub2api.yml"
readonly SUB2API_ENV_FILE="${SCRIPT_DIR}/sub2api.env"
readonly SUB2API_ENV_EXAMPLE_FILE="${SCRIPT_DIR}/sub2api.env.example"
readonly SUB2API_PROJECT_NAME="sub2api-manager"
readonly SUB2API_CONTAINER_NAME="sub2api-manager"
readonly SUB2API_POSTGRES_CONTAINER_NAME="sub2api-manager-postgres"
readonly SUB2API_REDIS_CONTAINER_NAME="sub2api-manager-redis"
readonly CURSOR_BRIDGE_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.cursor-bridge.yml"
readonly CURSOR_BRIDGE_ENV_FILE="${SCRIPT_DIR}/cursor-bridge.env"
readonly CURSOR_BRIDGE_ENV_EXAMPLE_FILE="${SCRIPT_DIR}/cursor-bridge.env.example"
readonly CURSOR_BRIDGE_PROJECT_NAME="cursor-bridge"
readonly CURSOR_BRIDGE_CONTAINER_NAME="cursor-bridge"
readonly CURSOR_BRIDGE_NETWORK="cpa-cursor-bridge"
readonly CURSOR_BRIDGE_SOURCE_REPOSITORY="https://github.com/anyrobert/cursor-api-proxy"
readonly CURSOR_BRIDGE_SOURCE_COMMIT="c0ff1f941215027c0a8f658ca5d01f806559208f"
readonly CURSOR_BRIDGE_IMAGE="cursor-api-proxy:poc-c0ff1f941215027c0a8f658ca5d01f806559208f"
readonly AUTO_UPDATE_LOG="${SCRIPT_DIR}/logs/auto-update.log"
readonly FAILED_UPDATE_FILE="${SCRIPT_DIR}/logs/failed-update-digest"
readonly AUTO_UPDATE_MARKER_BEGIN="# >>> cli-proxy-manager auto-update >>>"
readonly AUTO_UPDATE_MARKER_END="# <<< cli-proxy-manager auto-update <<<"

# 用户可配置（在 .env 中覆盖）
CPA_PORT="${CPA_PORT:-8317}"
CPA_API_KEY="${CPA_API_KEY:-}"
CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY:-}"
API_KEYS=()
SUB2API_ENV_CREATED=false
SUB2API_NEW_ADMIN_PASSWORD=""

# ========================== 颜色 & 样式 ======================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' NC=''
fi

# ========================== 日志函数 ==========================================

banner() {
    echo ""
    echo -e "${CYAN}"
    cat << 'EOF'
     _          _   _                       _ _
    / \   _ __ | |_(_) __ _ _ __ __ ___   _(_) |_ _   _
   / _ \ | '_ \| __| |/ _` | '__/ _` \ \ / / | __| | | |
  / ___ \| | | | |_| | (_| | | | (_| |\ V /| | |_| |_| |
 /_/   \_\_| |_|\__|_|\__, |_|  \__,_| \_/ |_|\__|\__, |
                       |___/    Proxy               |___/
EOF
    echo -e "${NC}"
    echo -e "  ${DIM}Powered by CLIProxyAPI · v${VERSION}${NC}"
    echo ""
}

info()    { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "  ${RED}✘${NC}  $*"; }
step()    { echo ""; echo -e "  ${BLUE}${BOLD}▸ $*${NC}"; }
detail()  { echo -e "     ${DIM}$*${NC}"; }
divider() { echo -e "  ${DIM}──────────────────────────────────────────${NC}"; }

ask() {
    local prompt="$1" default="${2:-}"
    if [[ -n "$default" ]]; then
        echo -en "  ${MAGENTA}?${NC}  ${prompt} ${DIM}[${default}]${NC}: "
    else
        echo -en "  ${MAGENTA}?${NC}  ${prompt}: "
    fi
}

confirm() {
    local prompt="$1" default="${2:-y}"
    if [[ "$default" == "y" ]]; then
        echo -en "  ${MAGENTA}?${NC}  ${prompt} ${DIM}[Y/n]${NC}: "
    else
        echo -en "  ${MAGENTA}?${NC}  ${prompt} ${DIM}[y/N]${NC}: "
    fi
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

# ========================== 环境检测 ==========================================

detect_compose() {
    if docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo ""
    fi
}

path_within_repo() {
    local path="$1" parent resolved
    parent="$(dirname "${path}")"
    resolved="$(cd "${parent}" 2>/dev/null && pwd -P)/$(basename "${path}")" || return 1
    [[ "${resolved}" == "${SCRIPT_DIR}"/* || "${resolved}" == "${SCRIPT_DIR}" ]]
}

assert_safe_path() {
    local path="$1" allow_missing="${2:-false}" current="${SCRIPT_DIR}" rel component
    path_within_repo "${path}" || { error "路径超出仓库根目录: ${path}"; return 1; }
    rel="${path#${SCRIPT_DIR}/}"
    IFS='/' read -r -a parts <<< "${rel}"
    for component in "${parts[@]}"; do
        current="${current}/${component}"
        if [[ -L "${current}" ]]; then error "拒绝符号链接路径: ${current}"; return 1; fi
        if [[ -e "${current}" && ! -f "${current}" && ! -d "${current}" ]]; then error "拒绝非普通路径: ${current}"; return 1; fi
    done
    if [[ "${allow_missing}" != "true" && ! -e "${path}" ]]; then error "路径不存在: ${path}"; return 1; fi
}

assert_regular_file() {
    local path="$1"
    assert_safe_path "${path}" false && [[ -f "${path}" && ! -L "${path}" ]] || { error "要求普通文件: ${path}"; return 1; }
}

check_prereqs() {
    step "检查运行环境"

    # Docker
    if ! command -v docker &>/dev/null; then
        error "未检测到 Docker"
        echo ""
        echo "     请先安装 Docker Desktop:"
        echo "     ${CYAN}https://www.docker.com/products/docker-desktop/${NC}"
        echo ""
        exit 1
    fi
    info "Docker 已安装"

    # Docker daemon
    if ! docker info &>/dev/null 2>&1; then
        error "Docker 守护进程未运行"
        echo "     请启动 Docker Desktop 后重试"
        exit 1
    fi
    info "Docker 守护进程运行中"

    # Docker Compose
    COMPOSE_CMD="$(detect_compose)"
    if [[ -z "$COMPOSE_CMD" ]]; then
        error "未检测到 Docker Compose"
        exit 1
    fi
    info "Docker Compose 可用"

    # Port check
    if lsof -i :"${CPA_PORT}" &>/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            warn "端口 ${CPA_PORT} 被本项目容器占用（将自动重建）"
        else
            error "端口 ${CPA_PORT} 已被其他程序占用"
            detail "请修改 CPA_PORT 环境变量或停止占用端口的程序"
            exit 1
        fi
    else
        info "端口 ${CPA_PORT} 可用"
    fi
}

# ========================== 交互式配置向导 ====================================

generate_key() {
    # 生成 sk- 前缀的随机 API key
    echo "sk-$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 32 || :)"
}

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

parse_api_keys() {
    local input="$1"
    local default_key="$2"
    local item key

    API_KEYS=()
    input="$(trim_value "$input")"

    if [[ -n "$input" ]]; then
        local old_ifs="$IFS"
        IFS=','
        for item in $input; do
            key="$(trim_value "$item")"
            [[ -n "$key" ]] && API_KEYS+=("$key")
        done
        IFS="$old_ifs"
    fi

    if [[ ${#API_KEYS[@]} -eq 0 ]]; then
        API_KEYS=("$default_key")
    fi

    CPA_API_KEY="${API_KEYS[0]}"
}

read_config_api_keys() {
    [[ -f "${CONFIG_FILE}" ]] || return 0
    awk '
        /^api-keys:[[:space:]]*$/ { in_keys=1; next }
        in_keys && /^[^[:space:]]/ { exit }
        in_keys && /^[[:space:]]*-[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /^".*"$/) {
                line=substr(line, 2, length(line) - 2)
            }
            if (line != "") {
                print line
            }
        }
    ' "${CONFIG_FILE}"
}

sync_api_key_from_config() {
    if [[ -z "${CPA_API_KEY}" && -f "${CONFIG_FILE}" ]]; then
        local first_key
        first_key="$(read_config_api_keys | head -1 || true)"
        CPA_API_KEY="${first_key:-}"
    fi
}

config_api_key_count() {
    read_config_api_keys | wc -l | tr -d '[:space:]'
}

# ========================== CPA 只读能力探针 =================================

capability_json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "${value}"
}

capability_json_string_or_null() {
    local value="${1:-}"
    if [[ -z "${value}" || "${value}" == "unknown" ]]; then
        printf 'null'
    else
        printf '"%s"' "$(capability_json_escape "${value}")"
    fi
}

capability_json_bool_or_null() {
    case "${1:-unknown}" in
        true|false) printf '%s' "$1" ;;
        *) printf 'null' ;;
    esac
}

capability_json_number_or_null() {
    local value="${1:-}"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        printf '%s' "${value}"
    else
        printf 'null'
    fi
}

capability_display_value() {
    local value="${1:-}"
    if [[ -z "${value}" || "${value}" == "unknown" ]]; then
        printf 'unavailable'
    else
        printf '%s' "${value}"
    fi
}

capability_display_bool() {
    case "${1:-unknown}" in
        true) printf 'yes' ;;
        false) printf 'no' ;;
        *) printf 'unavailable' ;;
    esac
}

capability_normalize_bool() {
    local value
    value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "${value}" in
        true|yes|on|1) printf 'true' ;;
        false|no|off|0) printf 'false' ;;
        *) printf 'unknown' ;;
    esac
}

capability_is_loopback() {
    case "${1:-}" in
        localhost|127.*|::1|\[::1\]|0:0:0:0:0:0:0:1) return 0 ;;
        *) return 1 ;;
    esac
}

capability_add_finding() {
    CAP_FINDING_CODES+=("$1")
    CAP_FINDING_SEVERITIES+=("$2")
    CAP_FINDING_MESSAGES+=("$3")
}

capability_yaml_value() {
    local value="$1"
    value="$(printf '%s' "${value}" | sed 's/[[:space:]]#.*$//')"
    value="$(trim_value "${value}")"
    if [[ ${#value} -ge 2 ]]; then
        if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        fi
    fi
    printf '%s' "${value}"
}

probe_remote_management_config() {
    CAP_REMOTE_CONFIGURED="false"
    CAP_REMOTE_ALLOW="unknown"
    CAP_REMOTE_PANEL_DISABLED="unknown"
    CAP_REMOTE_SECRET_CONFIGURED="unknown"

    [[ -f "${CONFIG_FILE}" ]] || return 0

    local in_remote=false line value
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^remote-management:[[:space:]]*($|#) ]]; then
            in_remote=true
            CAP_REMOTE_CONFIGURED="true"
            continue
        fi
        if $in_remote && [[ "${line}" =~ ^[^[:space:]#] ]]; then
            break
        fi
        $in_remote || continue

        if [[ "${line}" =~ ^[[:space:]]+allow-remote:[[:space:]]*(.*)$ ]]; then
            value="$(capability_yaml_value "${BASH_REMATCH[1]}")"
            CAP_REMOTE_ALLOW="$(capability_normalize_bool "${value}")"
        elif [[ "${line}" =~ ^[[:space:]]+disable-control-panel:[[:space:]]*(.*)$ ]]; then
            value="$(capability_yaml_value "${BASH_REMATCH[1]}")"
            CAP_REMOTE_PANEL_DISABLED="$(capability_normalize_bool "${value}")"
        elif [[ "${line}" =~ ^[[:space:]]+secret-key:[[:space:]]*(.*)$ ]]; then
            value="$(capability_yaml_value "${BASH_REMATCH[1]}")"
            if [[ -n "${value}" ]]; then
                CAP_REMOTE_SECRET_CONFIGURED="true"
            else
                CAP_REMOTE_SECRET_CONFIGURED="false"
            fi
        fi
    done < "${CONFIG_FILE}"
}

probe_routing_config() {
    CAP_ROUTING_STRATEGY="unknown"
    CAP_SESSION_AFFINITY_ENABLED="unknown"
    CAP_SESSION_AFFINITY_TTL="unknown"

    [[ -f "${CONFIG_FILE}" ]] || return 0

    CAP_ROUTING_STRATEGY="round-robin"
    CAP_SESSION_AFFINITY_ENABLED="false"
    CAP_SESSION_AFFINITY_TTL="1h"

    local in_routing=false line value
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^routing:[[:space:]]*($|#) ]]; then
            in_routing=true
            continue
        fi
        if $in_routing && [[ "${line}" =~ ^[^[:space:]#] ]]; then
            break
        fi
        $in_routing || continue

        if [[ "${line}" =~ ^[[:space:]]+strategy:[[:space:]]*(.*)$ ]]; then
            value="$(capability_yaml_value "${BASH_REMATCH[1]}")"
            case "${value}" in
                round-robin|weighted-round-robin|fill-first) CAP_ROUTING_STRATEGY="${value}" ;;
                *) CAP_ROUTING_STRATEGY="unknown" ;;
            esac
        elif [[ "${line}" =~ ^[[:space:]]+session-affinity:[[:space:]]*(.*)$ ]]; then
            value="$(capability_yaml_value "${BASH_REMATCH[1]}")"
            CAP_SESSION_AFFINITY_ENABLED="$(capability_normalize_bool "${value}")"
        elif [[ "${line}" =~ ^[[:space:]]+session-affinity-ttl:[[:space:]]*(.*)$ ]]; then
            value="$(capability_yaml_value "${BASH_REMATCH[1]}")"
            if [[ "${value}" =~ ^([0-9]+([.][0-9]+)?(ns|us|ms|s|m|h))+$ ]]; then
                CAP_SESSION_AFFINITY_TTL="${value}"
            else
                CAP_SESSION_AFFINITY_TTL="unknown"
            fi
        fi
    done < "${CONFIG_FILE}"
}

probe_plugin_config() {
    CAP_PLUGIN_CONFIGURED="false"
    CAP_PLUGIN_ENABLED="unknown"
    CAP_PLUGIN_CONFIG_SECTION="false"

    [[ -f "${CONFIG_FILE}" ]] || return 0

    local in_plugins=false line value
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^plugins:[[:space:]]*($|#) ]]; then
            in_plugins=true
            CAP_PLUGIN_CONFIG_SECTION="true"
            CAP_PLUGIN_CONFIGURED="true"
            continue
        fi
        if $in_plugins && [[ "${line}" =~ ^[^[:space:]#] ]]; then
            break
        fi
        $in_plugins || continue

        if [[ "${line}" =~ ^[[:space:]]+enabled:[[:space:]]*(.*)$ ]]; then
            value="$(capability_yaml_value "${BASH_REMATCH[1]}")"
            CAP_PLUGIN_ENABLED="$(capability_normalize_bool "${value}")"
        fi
    done < "${CONFIG_FILE}"
}

select_capability_binding() {
    local line host port priority selected="" selected_priority=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        [[ -z "${line}" ]] && continue
        host="" port=""
        if [[ "${line}" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        elif [[ "${line}" =~ ^(.*):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        fi
        [[ -z "${host}" || -z "${port}" ]] && continue

        if [[ "${host}" == "0.0.0.0" ]]; then
            priority=4
        elif [[ "${host}" == "::" ]]; then
            priority=3
        elif capability_is_loopback "${host}"; then
            priority=1
        else
            priority=2
        fi
        if (( priority > selected_priority )); then
            selected="${host}|${port}"
            selected_priority=${priority}
        fi
    done
    printf '%s' "${selected}"
}

capability_probe_host() {
    local address="${1:-}"
    case "${address}" in
        ""|0.0.0.0) printf '127.0.0.1' ;;
        ::) printf '[::1]' ;;
        \[*\]) printf '%s' "${address}" ;;
        *:*) printf '[%s]' "${address}" ;;
        *) printf '%s' "${address}" ;;
    esac
}

capability_header_value() {
    local headers="$1" wanted="$2" line name value lowered
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        [[ "${line}" == *:* ]] || continue
        name="${line%%:*}"
        value="${line#*:}"
        lowered="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${lowered}" == "${wanted}" ]]; then
            printf '%s' "$(trim_value "${value}")"
            return 0
        fi
    done <<< "${headers}"
}

count_models_in_response() {
    awk '
        {
            line=$0
            while (match(line, /"id"[[:space:]]*:/)) {
                count++
                line=substr(line, RSTART + RLENGTH)
            }
        }
        END { print count + 0 }
    '
}

capability_python_command() {
    local candidate
    for candidate in python3 python; do
        if command -v "${candidate}" &>/dev/null && "${candidate}" -c 'import json' &>/dev/null; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

reset_provider_credential_counts() {
    CAP_CREDENTIAL_INSPECTION="unknown"
    CAP_CREDENTIAL_SOURCE="unknown"
    CAP_CREDENTIAL_ANTIGRAVITY="unknown"
    CAP_CREDENTIAL_CLAUDE="unknown"
    CAP_CREDENTIAL_CODEX="unknown"
    CAP_CREDENTIAL_GEMINI="unknown"
    CAP_CREDENTIAL_KIMI="unknown"
    CAP_CREDENTIAL_XAI="unknown"
    CAP_CREDENTIAL_UNKNOWN="unknown"
    CAP_CREDENTIAL_TOTAL="unknown"
    CAP_ADDITIONAL_PROVIDER_TYPES=()
    CAP_ADDITIONAL_PROVIDER_COUNTS=()
}

probe_provider_credential_fallback() {
    reset_provider_credential_counts

    [[ "${CAP_CONTAINER_RUNNING}" == "true" ]] || return 0

    local output line provider count seen=0 total=0
    if ! output="$(docker exec "${CONTAINER_NAME}" sh -c '
        auth=/root/.cli-proxy-api
        [ -d "$auth" ] || exit 2
        antigravity=$(find "$auth" -maxdepth 1 -type f \( -name "antigravity.json" -o -name "antigravity-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]")
        claude=$(find "$auth" -maxdepth 1 -type f \( -name "claude.json" -o -name "claude-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]")
        codex=$(find "$auth" -maxdepth 1 -type f \( -name "codex.json" -o -name "codex-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]")
        gemini=$(find "$auth" -maxdepth 1 -type f \( -name "gemini.json" -o -name "gemini-*.json" -o -name "geminicli.json" -o -name "geminicli-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]")
        kimi=$(find "$auth" -maxdepth 1 -type f \( -name "kimi.json" -o -name "kimi-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]")
        xai=$(find "$auth" -maxdepth 1 -type f \( -name "xai.json" -o -name "xai-*.json" -o -name "x-ai.json" -o -name "x-ai-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]")
        all=$(find "$auth" -maxdepth 1 -type f -name "*.json" 2>/dev/null | wc -l | tr -d "[:space:]")
        printf "antigravity=%s\nclaude=%s\ncodex=%s\ngemini=%s\nkimi=%s\nxai=%s\nall=%s\n" \
            "${antigravity:-0}" "${claude:-0}" "${codex:-0}" "${gemini:-0}" "${kimi:-0}" "${xai:-0}" "${all:-0}"
    ' 2>/dev/null)"; then
        return 0
    fi

    local all_count="unknown" known_total=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        provider="${line%%=*}"
        count="${line#*=}"
        [[ "${count}" =~ ^[0-9]+$ ]] || continue
        case "${provider}" in
            antigravity) CAP_CREDENTIAL_ANTIGRAVITY="${count}" ;;
            claude) CAP_CREDENTIAL_CLAUDE="${count}" ;;
            codex) CAP_CREDENTIAL_CODEX="${count}" ;;
            gemini) CAP_CREDENTIAL_GEMINI="${count}" ;;
            kimi) CAP_CREDENTIAL_KIMI="${count}" ;;
            xai) CAP_CREDENTIAL_XAI="${count}" ;;
            all) all_count="${count}"; continue ;;
            *) continue ;;
        esac
        seen=$((seen + 1))
        known_total=$((known_total + count))
    done <<< "${output}"

    if [[ ${seen} -eq 6 && "${all_count}" =~ ^[0-9]+$ ]]; then
        if (( all_count >= known_total )); then
            CAP_CREDENTIAL_UNKNOWN=$((all_count - known_total))
        else
            CAP_CREDENTIAL_UNKNOWN=0
        fi
        CAP_CREDENTIAL_INSPECTION="available"
        CAP_CREDENTIAL_SOURCE="filename_fallback"
        CAP_CREDENTIAL_TOTAL="${all_count}"
    fi
}

parse_auth_files_inventory() {
    local body="$1" python output line key value
    python="$(capability_python_command || true)"
    [[ -n "${python}" ]] || return 1

    output="$(printf '%s' "${body}" | "${python}" -c '
import json, re, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
files = payload.get("files", []) if isinstance(payload, dict) else []
if not isinstance(files, list):
    raise SystemExit(2)
known = {key: 0 for key in ("antigravity", "claude", "codex", "gemini", "kimi", "xai")}
aliases = {"gemini-cli": "gemini", "geminicli": "gemini", "x-ai": "xai", "x_ai": "xai"}
additional = {}
unknown = 0
status_supported = False
priority_configured = False
weight_configured = False
for item in files:
    if not isinstance(item, dict):
        unknown += 1
        continue
    status_supported = status_supported or "status" in item or "status_message" in item
    priority_configured = priority_configured or "priority" in item
    weight_configured = weight_configured or "weight" in item
    raw = item.get("type") or item.get("provider")
    if not isinstance(raw, str):
        unknown += 1
        continue
    provider = raw.strip().lower()
    provider = aliases.get(provider, provider)
    if provider in known:
        known[provider] += 1
    elif re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", provider):
        additional[provider] = additional.get(provider, 0) + 1
    else:
        unknown += 1
for key in known:
    print(f"known:{key}={known[key]}")
print(f"unknown={unknown}")
print(f"total={len(files)}")
print(f"status_supported={str(status_supported).lower()}")
print(f"priority_configured={str(priority_configured).lower()}")
print(f"weight_configured={str(weight_configured).lower()}")
for key in sorted(additional):
    print(f"additional:{key}={additional[key]}")
' 2>/dev/null)" || return 1

    reset_provider_credential_counts
    CAP_CREDENTIAL_ANTIGRAVITY=0
    CAP_CREDENTIAL_CLAUDE=0
    CAP_CREDENTIAL_CODEX=0
    CAP_CREDENTIAL_GEMINI=0
    CAP_CREDENTIAL_KIMI=0
    CAP_CREDENTIAL_XAI=0
    CAP_CREDENTIAL_UNKNOWN=0
    CAP_AUTH_FILES_STATUS_FIELDS="false"
    CAP_AUTH_FILES_PRIORITY_FIELDS="false"
    CAP_AUTH_FILES_WEIGHT_FIELDS="false"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        key="${line%%=*}"
        value="${line#*=}"
        case "${key}" in
            known:antigravity) CAP_CREDENTIAL_ANTIGRAVITY="${value}" ;;
            known:claude) CAP_CREDENTIAL_CLAUDE="${value}" ;;
            known:codex) CAP_CREDENTIAL_CODEX="${value}" ;;
            known:gemini) CAP_CREDENTIAL_GEMINI="${value}" ;;
            known:kimi) CAP_CREDENTIAL_KIMI="${value}" ;;
            known:xai) CAP_CREDENTIAL_XAI="${value}" ;;
            unknown) CAP_CREDENTIAL_UNKNOWN="${value}" ;;
            total) CAP_CREDENTIAL_TOTAL="${value}" ;;
            status_supported) CAP_AUTH_FILES_STATUS_FIELDS="${value}" ;;
            priority_configured) CAP_AUTH_FILES_PRIORITY_FIELDS="${value}" ;;
            weight_configured) CAP_AUTH_FILES_WEIGHT_FIELDS="${value}" ;;
            additional:*)
                CAP_ADDITIONAL_PROVIDER_TYPES+=("${key#additional:}")
                CAP_ADDITIONAL_PROVIDER_COUNTS+=("${value}")
                ;;
        esac
    done <<< "${output}"

    [[ "${CAP_CREDENTIAL_TOTAL}" =~ ^[0-9]+$ ]] || return 1
    CAP_CREDENTIAL_INSPECTION="available"
    CAP_CREDENTIAL_SOURCE="management_api"
}

parse_management_config_capability() {
    local body="$1" python output line key value
    python="$(capability_python_command || true)"
    [[ -n "${python}" ]] || return 1

    output="$(printf '%s' "${body}" | "${python}" -c '
import json, re, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
if not isinstance(payload, dict):
    raise SystemExit(2)

priority_configured = False
weight_configured = False
credential_sections = (
    "gemini-api-key",
    "interactions-api-key",
    "claude-api-key",
    "vertex-api-key",
    "codex-api-key",
    "xai-api-key",
)
for section in credential_sections:
    entries = payload.get(section, [])
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        priority_configured = priority_configured or "priority" in entry
        weight_configured = weight_configured or "weight" in entry

compatibility_entries = payload.get("openai-compatibility", [])
if isinstance(compatibility_entries, list):
    for provider in compatibility_entries:
        if not isinstance(provider, dict):
            continue
        priority_configured = priority_configured or "priority" in provider
        api_key_entries = provider.get("api-key-entries", [])
        if isinstance(api_key_entries, list):
            for entry in api_key_entries:
                if isinstance(entry, dict):
                    weight_configured = weight_configured or "weight" in entry

routing = payload.get("routing", {})
if not isinstance(routing, dict):
    routing = {}
strategy = routing.get("strategy", "round-robin")
if strategy not in ("round-robin", "weighted-round-robin", "fill-first"):
    strategy = "unknown"
session_affinity = routing.get("session-affinity", False)
if not isinstance(session_affinity, bool):
    session_affinity = None
session_ttl = routing.get("session-affinity-ttl", "1h")
if not isinstance(session_ttl, str) or not re.fullmatch(r"(?:[0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h))+", session_ttl):
    session_ttl = "unknown"

print("priority_configured=" + str(priority_configured).lower())
print("weight_configured=" + str(weight_configured).lower())
print("strategy=" + strategy)
print("session_affinity=" + (str(session_affinity).lower() if isinstance(session_affinity, bool) else "unknown"))
print("session_affinity_ttl=" + session_ttl)
' 2>/dev/null)" || return 1

    CAP_CONFIG_PRIORITY_FIELDS="false"
    CAP_CONFIG_WEIGHT_FIELDS="false"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        key="${line%%=*}"
        value="${line#*=}"
        case "${key}" in
            priority_configured) CAP_CONFIG_PRIORITY_FIELDS="${value}" ;;
            weight_configured) CAP_CONFIG_WEIGHT_FIELDS="${value}" ;;
            strategy) CAP_ROUTING_STRATEGY="${value}" ;;
            session_affinity) CAP_SESSION_AFFINITY_ENABLED="${value}" ;;
            session_affinity_ttl) CAP_SESSION_AFFINITY_TTL="${value}" ;;
        esac
    done <<< "${output}"
}

parse_routing_strategy_capability() {
    local body="$1" python strategy
    python="$(capability_python_command || true)"
    [[ -n "${python}" ]] || return 1
    strategy="$(printf '%s' "${body}" | "${python}" -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
strategy = payload.get("strategy") if isinstance(payload, dict) else None
if strategy not in ("round-robin", "weighted-round-robin", "fill-first"):
    raise SystemExit(2)
print(strategy)
' 2>/dev/null)" || return 1
    CAP_ROUTING_STRATEGY="${strategy}"
}

parse_management_center_version() {
    local body="$1" python version
    python="$(capability_python_command || true)"
    [[ -n "${python}" ]] || return 1
    version="$(printf '%s' "${body}" | "${python}" -c '
import re, sys
body = sys.stdin.read()
match = re.search(r"footer\.version.{0,300}?tileValue.{0,160}?children:\s*[`\"](v[0-9]+\.[0-9]+\.[0-9]+)[`\"]", body, re.S)
if not match:
    raise SystemExit(2)
print(match.group(1))
' 2>/dev/null)" || return 1
    CAP_MANAGEMENT_UI_VERSION="${version}"
    CAP_MANAGEMENT_UI_VERSION_SOURCE="management_html"
}

combine_capability_flags() {
    local first="${1:-unknown}" second="${2:-unknown}"
    if [[ "${first}" == "true" || "${second}" == "true" ]]; then
        printf 'true'
    elif [[ "${first}" == "false" && "${second}" == "false" ]]; then
        printf 'false'
    else
        printf 'unknown'
    fi
}

reset_plugin_inventory() {
    CAP_PLUGIN_INSPECTION="unavailable"
    CAP_PLUGIN_INSPECTION_REASON="unknown"
    CAP_PLUGIN_SOURCE="unknown"
    CAP_PLUGIN_COUNT="unknown"
    CAP_PLUGIN_IDS=()
    CAP_PLUGIN_NAMES=()
    CAP_PLUGIN_VERSIONS=()
    CAP_PLUGIN_STATES=()
    CAP_PLUGIN_MENU_COUNTS=()
}

parse_plugin_inventory() {
    local body="$1" python output line id name version enabled menu_count plugins_enabled configured
    python="$(capability_python_command || true)"
    [[ -n "${python}" ]] || return 1

    output="$(printf '%s' "${body}" | "${python}" -c '
import json, re, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
if not isinstance(payload, dict) or not isinstance(payload.get("plugins", []), list):
    raise SystemExit(2)
plugins = payload.get("plugins", [])
enabled = payload.get("plugins_enabled")
print("plugins_enabled=" + (str(enabled).lower() if isinstance(enabled, bool) else "unknown"))
configured = False
safe_items = []
for index, item in enumerate(plugins, 1):
    if not isinstance(item, dict):
        continue
    configured = configured or item.get("configured") is True
    raw_id = item.get("id")
    plugin_id = raw_id.strip() if isinstance(raw_id, str) else ""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", plugin_id):
        plugin_id = f"redacted-plugin-{index}"
    metadata = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
    raw_name = metadata.get("name") or item.get("name")
    name = raw_name.strip() if isinstance(raw_name, str) else plugin_id
    if (not name or len(name) > 80 or re.search(r"[@\\/]|://|[\x00-\x1f]", name)
            or not re.fullmatch(r"[A-Za-z0-9 ._()+-]+", name)):
        name = plugin_id
    raw_version = metadata.get("version") or item.get("version")
    version = raw_version.strip() if isinstance(raw_version, str) else "unknown"
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+-]{0,31}", version):
        version = "unknown"
    state = item.get("effective_enabled")
    if not isinstance(state, bool):
        state = item.get("enabled")
    state_text = str(state).lower() if isinstance(state, bool) else "unknown"
    menus = item.get("menus")
    menu_count = len(menus) if isinstance(menus, list) else 0
    safe_items.append((plugin_id, name, version, state_text, menu_count))
print("configured=" + str(configured).lower())
print("count=" + str(len(safe_items)))
for item in safe_items:
    print("plugin\t" + "\t".join(str(value) for value in item))
' 2>/dev/null)" || return 1

    reset_plugin_inventory
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        case "${line}" in
            plugins_enabled=*) CAP_PLUGIN_ENABLED="${line#*=}" ;;
            configured=*)
                configured="${line#*=}"
                [[ "${configured}" == "true" ]] && CAP_PLUGIN_CONFIGURED="true"
                ;;
            count=*) CAP_PLUGIN_COUNT="${line#*=}" ;;
            plugin$'\t'*)
                IFS=$'\t' read -r _ id name version enabled menu_count <<< "${line}"
                CAP_PLUGIN_IDS+=("${id}")
                CAP_PLUGIN_NAMES+=("${name}")
                CAP_PLUGIN_VERSIONS+=("${version}")
                CAP_PLUGIN_STATES+=("${enabled}")
                CAP_PLUGIN_MENU_COUNTS+=("${menu_count}")
                ;;
        esac
    done <<< "${output}"

    [[ "${CAP_PLUGIN_COUNT}" =~ ^[0-9]+$ ]] || return 1
    CAP_PLUGIN_INSPECTION="available"
    CAP_PLUGIN_INSPECTION_REASON="unknown"
    CAP_PLUGIN_SOURCE="management_api"
}

probe_cpa_build_metadata_from_logs() {
    [[ "${CAP_CONTAINER_RUNNING}" == "true" ]] || return 0

    local output line version commit candidate
    output="$(docker logs --tail 5000 "${CONTAINER_NAME}" 2>&1 || true)"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ CLIProxyAPI[[:space:]]+Version:[[:space:]]*([vV]?[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            version="${BASH_REMATCH[1]}"
            if [[ "${line}" =~ Commit:[[:space:]]*([0-9a-fA-F]+) ]]; then
                candidate="${BASH_REMATCH[1]}"
                if (( ${#candidate} >= 7 && ${#candidate} <= 40 )); then
                    commit="${candidate}"
                fi
            fi
        fi
    done <<< "${output}"
    [[ -n "${version:-}" ]] && CAP_CPA_VERSION="${version}"
    [[ -n "${commit:-}" ]] && CAP_CPA_COMMIT="${commit}"
}

probe_plugin_binary_support() {
    [[ "${CAP_CONTAINER_RUNNING}" == "true" ]] || return 0

    local result
    result="$(docker exec "${CONTAINER_NAME}" sh -c '
        if ! command -v ldd >/dev/null 2>&1; then
            printf unknown
        elif ldd /proc/1/exe >/dev/null 2>&1; then
            printf true
        else
            printf false
        fi
    ' 2>/dev/null || true)"
    case "${result}" in
        true|false) CAP_PLUGIN_SYSTEM_SUPPORTED="${result}" ;;
    esac
}

capability_is_audited_v72102() {
    [[ "${CAP_CPA_VERSION}" == "v7.2.102" || "${CAP_CPA_VERSION}" == "7.2.102" ]] || return 1
    [[ "${CAP_CPA_COMMIT}" == 8423cce* ]]
}

capability_is_audited_v72111() {
    [[ "${CAP_CPA_VERSION}" == "${RELEASE_CONTRACT_CPA_VERSION}" || "${CAP_CPA_VERSION}" == "${RELEASE_CONTRACT_CPA_VERSION#v}" ]] || return 1
    [[ "${RELEASE_CONTRACT_CPA_COMMIT}" == "${CAP_CPA_COMMIT}"* ]]
}

apply_audited_cpa_contract() {
    local audited_version=""
    if capability_is_audited_v72111; then
        audited_version="v7.2.111"
        CAP_CPA_VERSION="${RELEASE_CONTRACT_CPA_VERSION}"
        CAP_CPA_COMMIT="${RELEASE_CONTRACT_CPA_COMMIT}"
        CAP_WEIGHTED_ROUND_ROBIN_SUPPORTED="true"
        CAP_PRIORITY_SUPPORTED="true"
        CAP_SESSION_AFFINITY_SUPPORTED="true"
        CAP_AUTOMATIC_FAILOVER_SUPPORTED="true"
    elif capability_is_audited_v72102; then
        audited_version="v7.2.102"
        CAP_PRIORITY_SUPPORTED="true"
    else
        return 0
    fi

    if [[ "${CAP_MANAGEMENT_AUTHENTICATED}" == "true" ]]; then
        CAP_OFFICIAL_CONTRACT_SOURCE="live_and_audited"
    else
        CAP_OFFICIAL_CONTRACT_SOURCE="audited_${audited_version}"
    fi
    CAP_MANAGEMENT_API_AVAILABLE="true"
    CAP_AUTH_FILES_INVENTORY_SUPPORT="true"
    CAP_ACCOUNT_STATUS_SUPPORT="true"
    CAP_PRIORITY_READ_SUPPORT="true"
    CAP_PRIORITY_WRITE_SUPPORT="true"
    CAP_QUOTA_RESET_SUPPORT="true"
    CAP_ROUTING_STRATEGY_SUPPORT="true"
    CAP_PLUGIN_RESOURCE_MANAGEMENT_AUTHENTICATED="false"
    CAP_PLUGIN_RESOURCE_VERIFICATION="audited_${audited_version}"
    if [[ "${CAP_PLUGIN_CONFIG_SECTION}" == "false" ]]; then
        CAP_PLUGIN_CONFIGURED="false"
        CAP_PLUGIN_ENABLED="false"
    fi
}

derive_release_contract_capability() {
    case "${CAP_ROUTING_STRATEGY}" in
        weighted-round-robin) CAP_WEIGHTED_ROUND_ROBIN_CONFIGURED="true" ;;
        round-robin|fill-first) CAP_WEIGHTED_ROUND_ROBIN_CONFIGURED="false" ;;
        *) CAP_WEIGHTED_ROUND_ROBIN_CONFIGURED="unknown" ;;
    esac

    CAP_PRIORITY_CONFIGURED="$(combine_capability_flags "${CAP_CONFIG_PRIORITY_FIELDS}" "${CAP_AUTH_FILES_PRIORITY_FIELDS}")"
    CAP_CREDENTIAL_WEIGHTS_CONFIGURED="$(combine_capability_flags "${CAP_CONFIG_WEIGHT_FIELDS}" "${CAP_AUTH_FILES_WEIGHT_FIELDS}")"

    CAP_RELEASE_COMPATIBILITY_STATUS="unknown"
    if [[ "${CAP_CPA_VERSION}" == "${RELEASE_CONTRACT_CPA_VERSION}" || "${CAP_CPA_VERSION}" == "${RELEASE_CONTRACT_CPA_VERSION#v}" ]]; then
        if [[ -z "${CAP_CPA_COMMIT}" || "${CAP_CPA_COMMIT}" == "unknown" ]]; then
            return 0
        fi
        if [[ "${RELEASE_CONTRACT_CPA_COMMIT}" != "${CAP_CPA_COMMIT}"* ]]; then
            CAP_RELEASE_COMPATIBILITY_STATUS="cpa_commit_mismatch"
        elif [[ "${CAP_MANAGEMENT_UI_VERSION}" == "unknown" ]]; then
            CAP_RELEASE_COMPATIBILITY_STATUS="unknown"
        elif [[ "${CAP_MANAGEMENT_UI_VERSION}" == "${RELEASE_CONTRACT_MANAGEMENT_CENTER_VERSION}" ]]; then
            CAP_RELEASE_COMPATIBILITY_STATUS="compatible"
        else
            CAP_RELEASE_COMPATIBILITY_STATUS="management_center_mismatch"
        fi
    elif [[ "${CAP_CPA_VERSION}" != "unknown" ]]; then
        CAP_RELEASE_COMPATIBILITY_STATUS="cpa_version_mismatch"
    fi
}

capability_authenticated_get() {
    local uri="$1" response
    CAP_HTTP_STATUS="unknown"
    CAP_HTTP_BODY=""
    response="$(curl -sS --max-time 5 -w $'\n__CPA_STATUS__:%{http_code}' \
        -H "Authorization: Bearer ${CPA_MANAGEMENT_KEY}" "${uri}" 2>/dev/null || true)"
    if [[ "${response}" == *$'\n__CPA_STATUS__:'* ]]; then
        CAP_HTTP_STATUS="${response##*$'\n__CPA_STATUS__:'}"
        CAP_HTTP_BODY="${response%$'\n__CPA_STATUS__:'*}"
    fi
}

probe_authenticated_management_api() {
    local base_url="$1" response status headers plugin_support
    if [[ -z "${CPA_MANAGEMENT_KEY:-}" ]]; then
        CAP_MANAGEMENT_AUTHENTICATED="unknown"
        CAP_PLUGIN_INSPECTION_REASON="management_key_unavailable"
        return 0
    fi

    response="$(curl -sS --max-time 5 -D - -o /dev/null -w $'\n__CPA_STATUS__:%{http_code}' \
        -H "Authorization: Bearer ${CPA_MANAGEMENT_KEY}" "${base_url}/v0/management/config" 2>/dev/null || true)"
    if [[ "${response}" != *$'\n__CPA_STATUS__:'* ]]; then
        CAP_PLUGIN_INSPECTION_REASON="management_api_unavailable"
        return 0
    fi
    status="${response##*$'\n__CPA_STATUS__:'}"
    headers="${response%$'\n__CPA_STATUS__:'*}"
    CAP_MANAGEMENT_CONFIG_HTTP_STATUS="${status}"

    if [[ "${status}" == "200" ]]; then
        CAP_MANAGEMENT_AUTHENTICATED="true"
        CAP_MANAGEMENT_API_AVAILABLE="true"
        if capability_is_audited_v72102 || capability_is_audited_v72111; then
            CAP_OFFICIAL_CONTRACT_SOURCE="live_and_audited"
        else
            CAP_OFFICIAL_CONTRACT_SOURCE="live"
        fi

        local header_value
        header_value="$(capability_header_value "${headers}" 'x-cpa-version')"
        [[ -n "${header_value}" ]] && CAP_CPA_VERSION="${header_value}"
        header_value="$(capability_header_value "${headers}" 'x-cpa-commit')"
        [[ -n "${header_value}" ]] && CAP_CPA_COMMIT="${header_value}"
        plugin_support="$(capability_header_value "${headers}" 'x-cpa-support-plugin')"
        case "${plugin_support}" in
            1|true) CAP_PLUGIN_SYSTEM_SUPPORTED="true" ;;
            0|false) CAP_PLUGIN_SYSTEM_SUPPORTED="false" ;;
        esac

        capability_authenticated_get "${base_url}/v0/management/config"
        if [[ "${CAP_HTTP_STATUS}" == "200" ]]; then
            parse_management_config_capability "${CAP_HTTP_BODY}" || true
        fi

        capability_authenticated_get "${base_url}/v0/management/auth-files"
        if [[ "${CAP_HTTP_STATUS}" == "200" ]] && parse_auth_files_inventory "${CAP_HTTP_BODY}"; then
            CAP_AUTH_FILES_INVENTORY_SUPPORT="true"
            [[ "${CAP_AUTH_FILES_STATUS_FIELDS}" == "true" ]] && CAP_ACCOUNT_STATUS_SUPPORT="true"
            [[ "${CAP_AUTH_FILES_PRIORITY_FIELDS}" == "true" ]] && CAP_PRIORITY_READ_SUPPORT="true"
        fi

        capability_authenticated_get "${base_url}/v0/management/plugins"
        if [[ "${CAP_HTTP_STATUS}" == "200" ]] && parse_plugin_inventory "${CAP_HTTP_BODY}"; then
            CAP_PLUGIN_SYSTEM_SUPPORTED="true"
        else
            CAP_PLUGIN_INSPECTION_REASON="plugin_api_unavailable"
        fi

        capability_authenticated_get "${base_url}/v0/management/routing/strategy"
        if [[ "${CAP_HTTP_STATUS}" == "200" ]]; then
            CAP_ROUTING_STRATEGY_SUPPORT="true"
            parse_routing_strategy_capability "${CAP_HTTP_BODY}" || true
        fi
    elif [[ "${status}" == "401" || "${status}" == "403" ]]; then
        CAP_MANAGEMENT_AUTHENTICATED="false"
        CAP_MANAGEMENT_API_AVAILABLE="true"
        CAP_PLUGIN_INSPECTION_REASON="management_key_rejected"
    else
        CAP_PLUGIN_INSPECTION_REASON="management_api_unavailable"
    fi
}

capability_file_epoch() {
    local file="$1" epoch=""
    epoch="$(stat -c '%Y' "${file}" 2>/dev/null || true)"
    if [[ ! "${epoch}" =~ ^[0-9]+$ ]]; then
        epoch="$(stat -f '%m' "${file}" 2>/dev/null || true)"
    fi
    [[ "${epoch}" =~ ^[0-9]+$ ]] && printf '%s' "${epoch}"
}

capability_epoch_to_iso() {
    local epoch="$1" result=""
    result="$(date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
    if [[ -z "${result}" ]]; then
        result="$(date -u -r "${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
    fi
    printf '%s' "${result}"
}

probe_latest_cpa_backup() {
    CAP_LATEST_BACKUP_TIME="unknown"
    local backup_dir="${SCRIPT_DIR}/backups" file base epoch latest_epoch=0
    [[ -d "${backup_dir}" ]] || return 0

    while IFS= read -r file || [[ -n "${file}" ]]; do
        base="$(basename "${file}")"
        [[ "${base}" == sub2api* ]] && continue
        epoch="$(capability_file_epoch "${file}")"
        if [[ "${epoch}" =~ ^[0-9]+$ ]] && (( epoch > latest_epoch )); then
            latest_epoch=${epoch}
        fi
    done < <(find "${backup_dir}" -maxdepth 1 -type f -name '*.tgz' -print 2>/dev/null)

    if (( latest_epoch > 0 )); then
        CAP_LATEST_BACKUP_TIME="$(capability_epoch_to_iso "${latest_epoch}")"
        [[ -n "${CAP_LATEST_BACKUP_TIME}" ]] || CAP_LATEST_BACKUP_TIME="unknown"
    fi
}

probe_cpa_capabilities() {
    CAP_SCHEMA_VERSION=1
    CAP_GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    CAP_MANAGER_VERSION="${VERSION}"
    CAP_DOCKER_CLI="false"
    CAP_DOCKER_DAEMON="false"
    CAP_COMPOSE_AVAILABLE="false"
    CAP_COMPOSE_VALID="unknown"
    CAP_CONFIG_STATE="missing"
    CAP_CONFIG_API_KEY_COUNT="unknown"
    CAP_CONFIGURED_BIND_ADDRESS="${CPA_BIND_HOST:-127.0.0.1}"
    CAP_CONFIGURED_BIND_PORT="${CPA_PORT:-8317}"
    CAP_ACTUAL_BIND_ADDRESS="unknown"
    CAP_ACTUAL_BIND_PORT="unknown"
    CAP_EXPOSURE_MODE="unknown"
    CAP_CONTAINER_RUNNING="unknown"
    CAP_IMAGE_REFERENCE="${DOCKER_IMAGE}"
    CAP_IMAGE_LOCAL_ID="unknown"
    CAP_IMAGE_REPOSITORY_DIGEST="unknown"
    CAP_CPA_VERSION="unknown"
    CAP_CPA_COMMIT="unknown"
    CAP_API_HEALTHY="unknown"
    CAP_HEALTH_HTTP_STATUS="unknown"
    CAP_MODELS_HTTP_STATUS="unknown"
    CAP_MODEL_COUNT="unknown"
    CAP_MANAGEMENT_UI_ENABLED="unknown"
    CAP_MANAGEMENT_UI_REACHABLE="unknown"
    CAP_MANAGEMENT_UI_HTTP_STATUS="unknown"
    CAP_MANAGEMENT_UI_LOCAL_URL="unknown"
    CAP_MANAGEMENT_UI_VERSION="unknown"
    CAP_MANAGEMENT_UI_VERSION_SOURCE="unknown"
    CAP_MANAGEMENT_UI_REMOTE_ALLOWED="unknown"
    CAP_MANAGEMENT_UI_EXTERNAL_HTTPS="unknown"
    CAP_MANAGEMENT_UI_PUBLIC_WARNING="unknown"
    CAP_MANAGEMENT_AUTHENTICATED="unknown"
    CAP_MANAGEMENT_CONFIG_HTTP_STATUS="unknown"
    CAP_OFFICIAL_CONTRACT_SOURCE="unknown"
    CAP_MANAGEMENT_API_AVAILABLE="unknown"
    CAP_AUTH_FILES_INVENTORY_SUPPORT="unknown"
    CAP_ACCOUNT_STATUS_SUPPORT="unknown"
    CAP_PRIORITY_READ_SUPPORT="unknown"
    CAP_PRIORITY_WRITE_SUPPORT="unknown"
    CAP_QUOTA_RESET_SUPPORT="unknown"
    CAP_ROUTING_STRATEGY_SUPPORT="unknown"
    CAP_PLUGIN_SYSTEM_SUPPORTED="unknown"
    CAP_PLUGIN_SYSTEM_CONFIGURED="unknown"
    CAP_PLUGIN_SYSTEM_ENABLED="unknown"
    CAP_PLUGIN_RESOURCE_MANAGEMENT_AUTHENTICATED="unknown"
    CAP_PLUGIN_RESOURCE_VERIFICATION="unknown"
    CAP_CRITICAL_PUBLIC_PLUGIN_RESOURCE_EXPOSURE="unknown"
    CAP_AUTH_FILES_STATUS_FIELDS="unknown"
    CAP_AUTH_FILES_PRIORITY_FIELDS="unknown"
    CAP_AUTH_FILES_WEIGHT_FIELDS="unknown"
    CAP_CONFIG_PRIORITY_FIELDS="unknown"
    CAP_CONFIG_WEIGHT_FIELDS="unknown"
    CAP_ROUTING_STRATEGY="unknown"
    CAP_WEIGHTED_ROUND_ROBIN_SUPPORTED="unknown"
    CAP_WEIGHTED_ROUND_ROBIN_CONFIGURED="unknown"
    CAP_PRIORITY_SUPPORTED="unknown"
    CAP_PRIORITY_CONFIGURED="unknown"
    CAP_CREDENTIAL_WEIGHTS_CONFIGURED="unknown"
    CAP_SESSION_AFFINITY_SUPPORTED="unknown"
    CAP_SESSION_AFFINITY_ENABLED="unknown"
    CAP_SESSION_AFFINITY_TTL="unknown"
    CAP_AUTOMATIC_FAILOVER_SUPPORTED="unknown"
    CAP_WRR_TRAFFIC_VALIDATION="not_run"
    CAP_RELEASE_COMPATIBILITY_STATUS="unknown"
    CAP_PREVIOUS_IMAGE_AVAILABLE="unknown"
    CAP_FINDING_CODES=()
    CAP_FINDING_SEVERITIES=()
    CAP_FINDING_MESSAGES=()
    reset_provider_credential_counts
    reset_plugin_inventory

    if [[ -d "${CONFIG_FILE}" ]]; then
        CAP_CONFIG_STATE="directory"
    elif [[ -f "${CONFIG_FILE}" ]]; then
        CAP_CONFIG_STATE="file"
        CAP_CONFIG_API_KEY_COUNT="$(config_api_key_count)"
    fi

    if command -v docker &>/dev/null; then
        CAP_DOCKER_CLI="true"
        if docker info &>/dev/null 2>&1; then
            CAP_DOCKER_DAEMON="true"
        fi
    fi

    COMPOSE_CMD="$(detect_compose)"
    if [[ -n "${COMPOSE_CMD}" ]]; then
        CAP_COMPOSE_AVAILABLE="true"
        if [[ -f "${CONFIG_FILE}" ]]; then
            if (cd "${SCRIPT_DIR}" && CPA_BIND_HOST="${CAP_CONFIGURED_BIND_ADDRESS}" CPA_PORT="${CAP_CONFIGURED_BIND_PORT}" CPA_IMAGE="${DOCKER_IMAGE}" ${COMPOSE_CMD} -f "${COMPOSE_FILE}" config --quiet >/dev/null 2>&1); then
                CAP_COMPOSE_VALID="true"
            else
                CAP_COMPOSE_VALID="false"
            fi
        fi
    fi

    if [[ "${CAP_DOCKER_DAEMON}" == "true" ]]; then
        local container_info image_ref image_id running port_output selected image_target repo_digests
        container_info="$(docker inspect --format '{{.Config.Image}}|{{.Image}}|{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
        if [[ -n "${container_info}" ]]; then
            IFS='|' read -r image_ref image_id running <<< "${container_info}"
            CAP_IMAGE_REFERENCE="${image_ref:-${DOCKER_IMAGE}}"
            CAP_IMAGE_LOCAL_ID="${image_id:-unknown}"
            CAP_CONTAINER_RUNNING="$(capability_normalize_bool "${running}")"
        else
            CAP_CONTAINER_RUNNING="false"
            CAP_IMAGE_LOCAL_ID="$(docker image inspect --format '{{.Id}}' "${CAP_IMAGE_REFERENCE}" 2>/dev/null | head -1 || true)"
            [[ -n "${CAP_IMAGE_LOCAL_ID}" ]] || CAP_IMAGE_LOCAL_ID="unknown"
        fi

        if [[ "${CAP_CONTAINER_RUNNING}" == "true" ]]; then
            port_output="$(docker port "${CONTAINER_NAME}" 8317/tcp 2>/dev/null || true)"
            selected="$(select_capability_binding <<< "${port_output}")"
            if [[ -n "${selected}" ]]; then
                CAP_ACTUAL_BIND_ADDRESS="${selected%%|*}"
                CAP_ACTUAL_BIND_PORT="${selected#*|}"
            fi
        fi

        image_target="${CAP_IMAGE_LOCAL_ID}"
        [[ "${image_target}" == "unknown" ]] && image_target="${CAP_IMAGE_REFERENCE}"
        repo_digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${image_target}" 2>/dev/null || true)"
        CAP_IMAGE_REPOSITORY_DIGEST="$(printf '%s\n' "${repo_digests}" | awk 'NF { print; exit }')"
        [[ -n "${CAP_IMAGE_REPOSITORY_DIGEST}" ]] || CAP_IMAGE_REPOSITORY_DIGEST="unknown"

        if docker image inspect "${ROLLBACK_IMAGE}" &>/dev/null 2>&1; then
            CAP_PREVIOUS_IMAGE_AVAILABLE="true"
        else
            CAP_PREVIOUS_IMAGE_AVAILABLE="false"
        fi

        probe_cpa_build_metadata_from_logs
        probe_plugin_binary_support
    fi

    local classification_address="${CAP_ACTUAL_BIND_ADDRESS}"
    [[ "${classification_address}" == "unknown" ]] && classification_address="${CAP_CONFIGURED_BIND_ADDRESS}"
    local exposure_hint
    exposure_hint="$(printf '%s' "${CPA_EXPOSURE_MODE:-}" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "${classification_address}" || "${classification_address}" == "unknown" ]]; then
        CAP_EXPOSURE_MODE="unknown"
    elif capability_is_loopback "${classification_address}"; then
        if [[ "${exposure_hint}" == "public-proxy" ]]; then
            CAP_EXPOSURE_MODE="public-proxy"
        else
            CAP_EXPOSURE_MODE="local"
        fi
    else
        CAP_EXPOSURE_MODE="direct-public"
    fi

    probe_remote_management_config
    probe_routing_config
    probe_plugin_config
    probe_latest_cpa_backup
    apply_audited_cpa_contract

    local probe_port="${CAP_ACTUAL_BIND_PORT}" probe_address="${CAP_ACTUAL_BIND_ADDRESS}"
    [[ "${probe_port}" == "unknown" ]] && probe_port="${CAP_CONFIGURED_BIND_PORT}"
    [[ "${probe_address}" == "unknown" ]] && probe_address="${CAP_CONFIGURED_BIND_ADDRESS}"

    if [[ "${CAP_CONTAINER_RUNNING}" == "true" && "${probe_port}" =~ ^[0-9]+$ ]]; then
        if command -v curl &>/dev/null; then
            local request_host base_url health_code management_response management_code management_body response body model_code
            request_host="$(capability_probe_host "${probe_address}")"
            base_url="http://${request_host}:${probe_port}"
            CAP_MANAGEMENT_UI_LOCAL_URL="${base_url}/management.html"

            health_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "${base_url}/healthz" 2>/dev/null || true)"
            [[ "${health_code}" =~ ^[0-9]{3}$ ]] && CAP_HEALTH_HTTP_STATUS="${health_code}"

            management_response="$(curl -sS --max-time 5 -w $'\n__CPA_STATUS__:%{http_code}' "${base_url}/management.html" 2>/dev/null || true)"
            if [[ "${management_response}" == *$'\n__CPA_STATUS__:'* ]]; then
                management_code="${management_response##*$'\n__CPA_STATUS__:'}"
                management_body="${management_response%$'\n__CPA_STATUS__:'*}"
            else
                management_code="unknown"
                management_body=""
            fi
            if [[ "${management_code}" =~ ^[0-9]{3}$ ]]; then
                CAP_MANAGEMENT_UI_HTTP_STATUS="${management_code}"
                if [[ "${management_code}" == "200" ]]; then
                    CAP_MANAGEMENT_UI_REACHABLE="true"
                    CAP_MANAGEMENT_UI_ENABLED="true"
                    parse_management_center_version "${management_body}" || true
                else
                    CAP_MANAGEMENT_UI_REACHABLE="false"
                fi
            fi

            sync_api_key_from_config
            if [[ -n "${CPA_API_KEY:-}" ]]; then
                if response="$(curl -sS --max-time 5 -w $'\n%{http_code}' "${base_url}/v1/models" -H "Authorization: Bearer ${CPA_API_KEY}" 2>/dev/null)"; then
                    model_code="${response##*$'\n'}"
                    body="${response%$'\n'*}"
                    if [[ "${model_code}" =~ ^[0-9]{3}$ ]]; then
                        CAP_MODELS_HTTP_STATUS="${model_code}"
                    fi
                    if [[ "${model_code}" == "200" ]]; then
                        CAP_MODEL_COUNT="$(printf '%s' "${body}" | count_models_in_response)"
                    fi
                fi
            fi

            if [[ "${CAP_HEALTH_HTTP_STATUS}" == "200" || "${CAP_MODELS_HTTP_STATUS}" == "200" ]]; then
                CAP_API_HEALTHY="true"
            elif [[ "${CAP_HEALTH_HTTP_STATUS}" != "unknown" || "${CAP_MODELS_HTTP_STATUS}" != "unknown" ]]; then
                CAP_API_HEALTHY="false"
            fi

            probe_authenticated_management_api "${base_url}"
        fi
    fi

    apply_audited_cpa_contract

    if [[ "${CAP_CREDENTIAL_SOURCE}" != "management_api" ]]; then
        probe_provider_credential_fallback
    fi

    if [[ "${CAP_MANAGEMENT_UI_ENABLED}" == "unknown" ]]; then
        case "${CAP_REMOTE_PANEL_DISABLED}" in
            true) CAP_MANAGEMENT_UI_ENABLED="false" ;;
            false) CAP_MANAGEMENT_UI_ENABLED="true" ;;
        esac
    fi
    CAP_MANAGEMENT_UI_REMOTE_ALLOWED="${CAP_REMOTE_ALLOW}"
    CAP_PLUGIN_SYSTEM_CONFIGURED="${CAP_PLUGIN_CONFIGURED}"
    CAP_PLUGIN_SYSTEM_ENABLED="${CAP_PLUGIN_ENABLED}"
    derive_release_contract_capability

    if [[ "${CAP_EXPOSURE_MODE}" == "local" || "${CAP_MANAGEMENT_UI_ENABLED}" == "false" ]]; then
        CAP_MANAGEMENT_UI_PUBLIC_WARNING="none"
    elif [[ "${CAP_EXPOSURE_MODE}" == "direct-public" && "${CAP_MANAGEMENT_UI_ENABLED}" == "true" && "${CAP_REMOTE_ALLOW}" == "true" ]]; then
        CAP_MANAGEMENT_UI_PUBLIC_WARNING="critical"
    elif [[ "${CAP_EXPOSURE_MODE}" == "direct-public" || "${CAP_EXPOSURE_MODE}" == "public-proxy" ]]; then
        CAP_MANAGEMENT_UI_PUBLIC_WARNING="warning"
    fi

    if [[ "${CAP_PLUGIN_RESOURCE_MANAGEMENT_AUTHENTICATED}" == "false" && "${CAP_PLUGIN_SYSTEM_SUPPORTED}" == "true" ]]; then
        if [[ "${CAP_EXPOSURE_MODE}" == "direct-public" && "${CAP_REMOTE_ALLOW}" == "true" ]]; then
            CAP_CRITICAL_PUBLIC_PLUGIN_RESOURCE_EXPOSURE="true"
        else
            CAP_CRITICAL_PUBLIC_PLUGIN_RESOURCE_EXPOSURE="false"
        fi
    fi

    if [[ "${CAP_DOCKER_CLI}" != "true" ]]; then
        capability_add_finding "DOCKER_CLI_UNAVAILABLE" "failure" "Docker CLI is unavailable."
    elif [[ "${CAP_DOCKER_DAEMON}" != "true" ]]; then
        capability_add_finding "DOCKER_DAEMON_UNAVAILABLE" "failure" "Docker daemon is unavailable."
    fi
    if [[ "${CAP_COMPOSE_AVAILABLE}" != "true" ]]; then
        capability_add_finding "COMPOSE_UNAVAILABLE" "failure" "Docker Compose is unavailable."
    elif [[ "${CAP_COMPOSE_VALID}" == "false" ]]; then
        capability_add_finding "COMPOSE_CONFIG_INVALID" "failure" "docker-compose.yml did not pass validation."
    fi
    case "${CAP_CONFIG_STATE}" in
        directory) capability_add_finding "CONFIG_IS_DIRECTORY" "failure" "config.yaml is a directory, not a file." ;;
        missing) capability_add_finding "CONFIG_MISSING" "failure" "config.yaml is missing." ;;
    esac
    if [[ "${CAP_CONFIG_STATE}" == "file" && "${CAP_CONFIG_API_KEY_COUNT}" == "0" ]]; then
        capability_add_finding "API_KEYS_MISSING" "failure" "No API keys were found in config.yaml."
    fi
    if [[ "${CAP_CONTAINER_RUNNING}" == "false" ]]; then
        capability_add_finding "CONTAINER_NOT_RUNNING" "warning" "The CPA container is not running."
    elif [[ "${CAP_CONTAINER_RUNNING}" == "true" && "${CAP_ACTUAL_BIND_ADDRESS}" == "unknown" ]]; then
        capability_add_finding "PORT_MAPPING_UNAVAILABLE" "warning" "The actual CPA port mapping could not be read."
    fi
    if [[ "${CAP_EXPOSURE_MODE}" == "direct-public" ]]; then
        capability_add_finding "DIRECT_PUBLIC_EXPOSURE" "warning" "CPA is bound directly to a public interface (${classification_address}:${probe_port})."
        capability_add_finding "PUBLIC_PROTECTION_UNVERIFIED" "warning" "TLS, firewall/source limits, and rate limits cannot be verified by this local probe."
        if [[ "${CAP_REMOTE_ALLOW}" == "true" ]]; then
            capability_add_finding "REMOTE_MANAGEMENT_PUBLIC" "warning" "Remote management is allowed while CPA is directly public."
            if [[ "${CAP_REMOTE_PANEL_DISABLED}" == "false" ]]; then
                capability_add_finding "PUBLIC_CONTROL_PANEL_ENABLED" "warning" "The management control panel is enabled on the direct-public CPA endpoint."
            fi
            if [[ "${CAP_REMOTE_SECRET_CONFIGURED}" == "false" ]]; then
                capability_add_finding "REMOTE_MANAGEMENT_SECRET_MISSING" "failure" "Remote management is public but no management secret is configured."
            fi
        fi
    elif [[ "${CAP_EXPOSURE_MODE}" == "public-proxy" ]]; then
        capability_add_finding "PUBLIC_PROXY_PROTECTION_UNVERIFIED" "warning" "External HTTPS and proxy access controls cannot be verified by this local probe."
    fi
    if [[ "${CAP_MANAGEMENT_UI_ENABLED}" == "true" && "${CAP_MANAGEMENT_UI_REACHABLE}" == "false" ]]; then
        capability_add_finding "MANAGEMENT_UI_UNREACHABLE" "warning" "The management UI is enabled but its local page did not return HTTP 200."
    fi
    if [[ "${CAP_CRITICAL_PUBLIC_PLUGIN_RESOURCE_EXPOSURE}" == "true" ]]; then
        capability_add_finding "PUBLIC_PLUGIN_RESOURCES_UNAUTHENTICATED" "critical" "CPA plugin resource pages are not protected by management authentication while remote management is exposed over direct-public HTTP."
    fi
    if [[ "${CAP_PLUGIN_SYSTEM_SUPPORTED}" == "true" && "${CAP_PLUGIN_INSPECTION}" != "available" ]]; then
        capability_add_finding "PLUGIN_INSPECTION_UNAVAILABLE" "warning" "Plugin support is available, but installed plugins could not be inspected through the authenticated Management API."
    fi
    if [[ "${exposure_hint}" == "public-proxy" && "${CAP_EXPOSURE_MODE}" == "direct-public" ]]; then
        capability_add_finding "EXPOSURE_HINT_MISMATCH" "warning" "CPA_EXPOSURE_MODE says public-proxy, but the actual binding is public."
    fi
    if [[ "${CAP_CONTAINER_RUNNING}" == "true" ]]; then
        if [[ "${CAP_API_HEALTHY}" == "false" ]]; then
            capability_add_finding "API_UNHEALTHY" "failure" "The local CPA health check failed."
        elif [[ "${CAP_API_HEALTHY}" == "unknown" ]]; then
            capability_add_finding "API_HEALTH_UNKNOWN" "warning" "The local CPA health check could not be completed."
        fi
        if [[ "${CAP_MODELS_HTTP_STATUS}" == "401" ]]; then
            capability_add_finding "MODELS_AUTH_FAILED" "failure" "/v1/models rejected the configured API key."
        elif [[ "${CAP_MODELS_HTTP_STATUS}" == "unknown" ]]; then
            capability_add_finding "MODELS_CHECK_UNKNOWN" "warning" "/v1/models could not be checked."
        elif [[ "${CAP_MODELS_HTTP_STATUS}" == "200" && "${CAP_MODEL_COUNT}" == "0" ]]; then
            capability_add_finding "MODELS_EMPTY" "warning" "/v1/models is healthy but returned no models."
        fi
    fi
    if [[ "${CAP_CREDENTIAL_INSPECTION}" == "unknown" ]]; then
        capability_add_finding "CREDENTIAL_INSPECTION_UNKNOWN" "warning" "Provider credential counts could not be inspected read-only."
    elif [[ "${CAP_CREDENTIAL_TOTAL}" == "0" ]]; then
        capability_add_finding "NO_PROVIDER_CREDENTIALS" "warning" "No provider credentials were found."
    fi
    if [[ "${CAP_LATEST_BACKUP_TIME}" == "unknown" ]]; then
        capability_add_finding "NO_CPA_BACKUP" "warning" "No CPA backup archive was found."
    fi
    if [[ "${CAP_PREVIOUS_IMAGE_AVAILABLE}" == "false" ]]; then
        capability_add_finding "NO_PREVIOUS_IMAGE" "warning" "No previous-image recovery target is available."
    fi
}

render_cpa_capabilities_human() {
    echo ""
    echo "  CLI Proxy Manager capabilities (schema v${CAP_SCHEMA_VERSION})"
    echo ""
    printf '  Manager version:          %s\n' "${CAP_MANAGER_VERSION}"
    printf '  CPA container running:    %s\n' "$(capability_display_bool "${CAP_CONTAINER_RUNNING}")"
    printf '  Configured binding:       %s:%s\n' "$(capability_display_value "${CAP_CONFIGURED_BIND_ADDRESS}")" "$(capability_display_value "${CAP_CONFIGURED_BIND_PORT}")"
    if [[ "${CAP_ACTUAL_BIND_ADDRESS}" == "unknown" ]]; then
        printf '  Actual binding:           unavailable\n'
    else
        printf '  Actual binding:           %s:%s\n' "${CAP_ACTUAL_BIND_ADDRESS}" "$(capability_display_value "${CAP_ACTUAL_BIND_PORT}")"
    fi
    printf '  Exposure mode:            %s\n' "$(capability_display_value "${CAP_EXPOSURE_MODE}")"
    printf '  Image reference:          %s\n' "$(capability_display_value "${CAP_IMAGE_REFERENCE}")"
    printf '  Local image ID:           %s\n' "$(capability_display_value "${CAP_IMAGE_LOCAL_ID}")"
    printf '  Repository digest:        %s\n' "$(capability_display_value "${CAP_IMAGE_REPOSITORY_DIGEST}")"
    printf '  CPA version:              %s\n' "$(capability_display_value "${CAP_CPA_VERSION}")"
    printf '  CPA commit:               %s\n' "$(capability_display_value "${CAP_CPA_COMMIT}")"
    printf '  Release contract:         CPA %s@%s, Management Center %s@%s\n' \
        "${RELEASE_CONTRACT_CPA_VERSION}" "${RELEASE_CONTRACT_CPA_COMMIT}" \
        "${RELEASE_CONTRACT_MANAGEMENT_CENTER_VERSION}" "${RELEASE_CONTRACT_MANAGEMENT_CENTER_COMMIT}"
    printf '  Contract compatibility:   source=exact_release_tags, target_pair=yes, runtime=%s\n' \
        "$(capability_display_value "${CAP_RELEASE_COMPATIBILITY_STATUS}")"
    printf '  API healthy:              %s (healthz=%s, models=%s)\n' \
        "$(capability_display_bool "${CAP_API_HEALTHY}")" \
        "$(capability_display_value "${CAP_HEALTH_HTTP_STATUS}")" \
        "$(capability_display_value "${CAP_MODELS_HTTP_STATUS}")"
    printf '  Model count:              %s\n' "$(capability_display_value "${CAP_MODEL_COUNT}")"
    printf '  Remote management:        configured=%s, allow_remote=%s, panel_disabled=%s, secret_configured=%s\n' \
        "$(capability_display_bool "${CAP_REMOTE_CONFIGURED}")" \
        "$(capability_display_bool "${CAP_REMOTE_ALLOW}")" \
        "$(capability_display_bool "${CAP_REMOTE_PANEL_DISABLED}")" \
        "$(capability_display_bool "${CAP_REMOTE_SECRET_CONFIGURED}")"
    printf '  Management UI:            enabled=%s, reachable=%s, http=%s\n' \
        "$(capability_display_bool "${CAP_MANAGEMENT_UI_ENABLED}")" \
        "$(capability_display_bool "${CAP_MANAGEMENT_UI_REACHABLE}")" \
        "$(capability_display_value "${CAP_MANAGEMENT_UI_HTTP_STATUS}")"
    printf '  Management Center:        version=%s, source=%s\n' \
        "$(capability_display_value "${CAP_MANAGEMENT_UI_VERSION}")" \
        "$(capability_display_value "${CAP_MANAGEMENT_UI_VERSION_SOURCE}")"
    printf '  Management local URL:     %s\n' "$(capability_display_value "${CAP_MANAGEMENT_UI_LOCAL_URL}")"
    printf '  Management protection:    remote_allowed=%s, external_https=%s, public_warning=%s\n' \
        "$(capability_display_bool "${CAP_MANAGEMENT_UI_REMOTE_ALLOWED}")" \
        "$(capability_display_bool "${CAP_MANAGEMENT_UI_EXTERNAL_HTTPS}")" \
        "$(capability_display_value "${CAP_MANAGEMENT_UI_PUBLIC_WARNING}")"
    printf '  Official capabilities:    management_api=%s, auth_files=%s, account_status=%s\n' \
        "$(capability_display_bool "${CAP_MANAGEMENT_API_AVAILABLE}")" \
        "$(capability_display_bool "${CAP_AUTH_FILES_INVENTORY_SUPPORT}")" \
        "$(capability_display_bool "${CAP_ACCOUNT_STATUS_SUPPORT}")"
    printf '  Priority and routing:     priority_read=%s, priority_write=%s, quota_reset=%s, routing=%s\n' \
        "$(capability_display_bool "${CAP_PRIORITY_READ_SUPPORT}")" \
        "$(capability_display_bool "${CAP_PRIORITY_WRITE_SUPPORT}")" \
        "$(capability_display_bool "${CAP_QUOTA_RESET_SUPPORT}")" \
        "$(capability_display_bool "${CAP_ROUTING_STRATEGY_SUPPORT}")"
    printf '  Routing contract:         strategy=%s, wrr_supported=%s, wrr_configured=%s\n' \
        "$(capability_display_value "${CAP_ROUTING_STRATEGY}")" \
        "$(capability_display_bool "${CAP_WEIGHTED_ROUND_ROBIN_SUPPORTED}")" \
        "$(capability_display_bool "${CAP_WEIGHTED_ROUND_ROBIN_CONFIGURED}")"
    printf '  Credential routing:       priority_supported=%s, priority_configured=%s, weights_configured=%s\n' \
        "$(capability_display_bool "${CAP_PRIORITY_SUPPORTED}")" \
        "$(capability_display_bool "${CAP_PRIORITY_CONFIGURED}")" \
        "$(capability_display_bool "${CAP_CREDENTIAL_WEIGHTS_CONFIGURED}")"
    printf '  Session affinity:         supported=%s, enabled=%s, ttl=%s\n' \
        "$(capability_display_bool "${CAP_SESSION_AFFINITY_SUPPORTED}")" \
        "$(capability_display_bool "${CAP_SESSION_AFFINITY_ENABLED}")" \
        "$(capability_display_value "${CAP_SESSION_AFFINITY_TTL}")"
    printf '  Failover / WRR test:      automatic_failover=%s, traffic_validation=%s\n' \
        "$(capability_display_bool "${CAP_AUTOMATIC_FAILOVER_SUPPORTED}")" \
        "${CAP_WRR_TRAFFIC_VALIDATION}"
    printf '  Plugin system:            supported=%s, configured=%s, enabled=%s, inspection=%s\n' \
        "$(capability_display_bool "${CAP_PLUGIN_SYSTEM_SUPPORTED}")" \
        "$(capability_display_bool "${CAP_PLUGIN_SYSTEM_CONFIGURED}")" \
        "$(capability_display_bool "${CAP_PLUGIN_SYSTEM_ENABLED}")" \
        "${CAP_PLUGIN_INSPECTION}"
    if [[ "${CAP_PLUGIN_INSPECTION}" == "available" ]]; then
        local plugin_index
        printf '  Installed plugins:        %s\n' "${CAP_PLUGIN_COUNT}"
        for ((plugin_index = 0; plugin_index < ${#CAP_PLUGIN_IDS[@]}; plugin_index++)); do
            printf '    - %s | %s | version=%s | enabled=%s | menus=%s\n' \
                "${CAP_PLUGIN_IDS[$plugin_index]}" "${CAP_PLUGIN_NAMES[$plugin_index]}" \
                "$(capability_display_value "${CAP_PLUGIN_VERSIONS[$plugin_index]}")" \
                "$(capability_display_bool "${CAP_PLUGIN_STATES[$plugin_index]}")" \
                "${CAP_PLUGIN_MENU_COUNTS[$plugin_index]}"
        done
    else
        printf '  Plugin inspection reason: %s\n' "$(capability_display_value "${CAP_PLUGIN_INSPECTION_REASON}")"
    fi
    printf '  Plugin resource auth:     management_authenticated=%s, verification=%s\n' \
        "$(capability_display_bool "${CAP_PLUGIN_RESOURCE_MANAGEMENT_AUTHENTICATED}")" \
        "$(capability_display_value "${CAP_PLUGIN_RESOURCE_VERIFICATION}")"
    if [[ "${CAP_CREDENTIAL_INSPECTION}" == "available" ]]; then
        printf '  Provider credentials:     source=%s, antigravity=%s, claude=%s, codex=%s, gemini=%s, kimi=%s, xai=%s, unknown=%s, total=%s\n' \
            "${CAP_CREDENTIAL_SOURCE}" "${CAP_CREDENTIAL_ANTIGRAVITY}" "${CAP_CREDENTIAL_CLAUDE}" "${CAP_CREDENTIAL_CODEX}" \
            "${CAP_CREDENTIAL_GEMINI}" "${CAP_CREDENTIAL_KIMI}" "${CAP_CREDENTIAL_XAI}" "${CAP_CREDENTIAL_UNKNOWN}" "${CAP_CREDENTIAL_TOTAL}"
        local provider_index
        for ((provider_index = 0; provider_index < ${#CAP_ADDITIONAL_PROVIDER_TYPES[@]}; provider_index++)); do
            printf '    - future provider %s=%s\n' "${CAP_ADDITIONAL_PROVIDER_TYPES[$provider_index]}" "${CAP_ADDITIONAL_PROVIDER_COUNTS[$provider_index]}"
        done
    else
        printf '  Provider credentials:     unavailable\n'
    fi
    printf '  Latest CPA backup time:   %s\n' "$(capability_display_value "${CAP_LATEST_BACKUP_TIME}")"
    printf '  Previous image available: %s\n' "$(capability_display_bool "${CAP_PREVIOUS_IMAGE_AVAILABLE}")"

    if [[ ${#CAP_FINDING_CODES[@]} -gt 0 ]]; then
        echo ""
        echo "  Findings:"
        local i
        for ((i = 0; i < ${#CAP_FINDING_CODES[@]}; i++)); do
            printf '  - [%s] %s: %s\n' "${CAP_FINDING_SEVERITIES[$i]}" "${CAP_FINDING_CODES[$i]}" "${CAP_FINDING_MESSAGES[$i]}"
        done
    fi
    echo ""
}

render_cpa_capabilities_json() {
    local i
    printf '{\n'
    printf '  "schema_version": %s,\n' "${CAP_SCHEMA_VERSION}"
    printf '  "generated_at": '; capability_json_string_or_null "${CAP_GENERATED_AT}"; printf ',\n'
    printf '  "manager": {"version": '; capability_json_string_or_null "${CAP_MANAGER_VERSION}"; printf '},\n'
    printf '  "container": {"name": '; capability_json_string_or_null "${CONTAINER_NAME}"; printf ', "running": '; capability_json_bool_or_null "${CAP_CONTAINER_RUNNING}"; printf '},\n'
    printf '  "network": {\n'
    printf '    "configured_address": '; capability_json_string_or_null "${CAP_CONFIGURED_BIND_ADDRESS}"; printf ',\n'
    printf '    "configured_port": '; capability_json_number_or_null "${CAP_CONFIGURED_BIND_PORT}"; printf ',\n'
    printf '    "actual_address": '; capability_json_string_or_null "${CAP_ACTUAL_BIND_ADDRESS}"; printf ',\n'
    printf '    "actual_port": '; capability_json_number_or_null "${CAP_ACTUAL_BIND_PORT}"; printf ',\n'
    printf '    "exposure_mode": '; capability_json_string_or_null "${CAP_EXPOSURE_MODE}"; printf '\n'
    printf '  },\n'
    printf '  "image": {\n'
    printf '    "reference": '; capability_json_string_or_null "${CAP_IMAGE_REFERENCE}"; printf ',\n'
    printf '    "local_id": '; capability_json_string_or_null "${CAP_IMAGE_LOCAL_ID}"; printf ',\n'
    printf '    "repository_digest": '; capability_json_string_or_null "${CAP_IMAGE_REPOSITORY_DIGEST}"; printf '\n'
    printf '  },\n'
    printf '  "cpa": {"version": '; capability_json_string_or_null "${CAP_CPA_VERSION}"; printf ', "commit": '; capability_json_string_or_null "${CAP_CPA_COMMIT}"; printf '},\n'
    printf '  "release_contract": {\n'
    printf '    "cpa_version": '; capability_json_string_or_null "${RELEASE_CONTRACT_CPA_VERSION}"; printf ',\n'
    printf '    "cpa_commit": '; capability_json_string_or_null "${RELEASE_CONTRACT_CPA_COMMIT}"; printf ',\n'
    printf '    "management_center_version": '; capability_json_string_or_null "${RELEASE_CONTRACT_MANAGEMENT_CENTER_VERSION}"; printf ',\n'
    printf '    "management_center_commit": '; capability_json_string_or_null "${RELEASE_CONTRACT_MANAGEMENT_CENTER_COMMIT}"; printf ',\n'
    printf '    "source": "exact_release_tags",\n'
    printf '    "target_pair_compatible": true,\n'
    printf '    "compatibility_status": '; capability_json_string_or_null "${CAP_RELEASE_COMPATIBILITY_STATUS}"; printf '\n'
    printf '  },\n'
    printf '  "api": {\n'
    printf '    "healthy": '; capability_json_bool_or_null "${CAP_API_HEALTHY}"; printf ',\n'
    printf '    "health_http_status": '; capability_json_number_or_null "${CAP_HEALTH_HTTP_STATUS}"; printf ',\n'
    printf '    "models_http_status": '; capability_json_number_or_null "${CAP_MODELS_HTTP_STATUS}"; printf ',\n'
    printf '    "model_count": '; capability_json_number_or_null "${CAP_MODEL_COUNT}"; printf '\n'
    printf '  },\n'
    printf '  "remote_management": {\n'
    printf '    "configured": '; capability_json_bool_or_null "${CAP_REMOTE_CONFIGURED}"; printf ',\n'
    printf '    "allow_remote": '; capability_json_bool_or_null "${CAP_REMOTE_ALLOW}"; printf ',\n'
    printf '    "control_panel_disabled": '; capability_json_bool_or_null "${CAP_REMOTE_PANEL_DISABLED}"; printf ',\n'
    printf '    "secret_configured": '; capability_json_bool_or_null "${CAP_REMOTE_SECRET_CONFIGURED}"; printf '\n'
    printf '  },\n'
    printf '  "management_ui": {\n'
    printf '    "enabled": '; capability_json_bool_or_null "${CAP_MANAGEMENT_UI_ENABLED}"; printf ',\n'
    printf '    "reachable": '; capability_json_bool_or_null "${CAP_MANAGEMENT_UI_REACHABLE}"; printf ',\n'
    printf '    "http_status": '; capability_json_number_or_null "${CAP_MANAGEMENT_UI_HTTP_STATUS}"; printf ',\n'
    printf '    "local_url": '; capability_json_string_or_null "${CAP_MANAGEMENT_UI_LOCAL_URL}"; printf ',\n'
    printf '    "version": '; capability_json_string_or_null "${CAP_MANAGEMENT_UI_VERSION}"; printf ',\n'
    printf '    "version_source": '; capability_json_string_or_null "${CAP_MANAGEMENT_UI_VERSION_SOURCE}"; printf ',\n'
    printf '    "remote_access_allowed": '; capability_json_bool_or_null "${CAP_MANAGEMENT_UI_REMOTE_ALLOWED}"; printf ',\n'
    printf '    "external_https_protection": '; capability_json_bool_or_null "${CAP_MANAGEMENT_UI_EXTERNAL_HTTPS}"; printf ',\n'
    printf '    "public_access_warning": '; capability_json_string_or_null "${CAP_MANAGEMENT_UI_PUBLIC_WARNING}"; printf '\n'
    printf '  },\n'
    printf '  "official_capabilities": {\n'
    printf '    "contract_source": '; capability_json_string_or_null "${CAP_OFFICIAL_CONTRACT_SOURCE}"; printf ',\n'
    printf '    "management_api_available": '; capability_json_bool_or_null "${CAP_MANAGEMENT_API_AVAILABLE}"; printf ',\n'
    printf '    "auth_files_inventory_supported": '; capability_json_bool_or_null "${CAP_AUTH_FILES_INVENTORY_SUPPORT}"; printf ',\n'
    printf '    "account_status_supported": '; capability_json_bool_or_null "${CAP_ACCOUNT_STATUS_SUPPORT}"; printf ',\n'
    printf '    "priority_read_supported": '; capability_json_bool_or_null "${CAP_PRIORITY_READ_SUPPORT}"; printf ',\n'
    printf '    "priority_write_supported": '; capability_json_bool_or_null "${CAP_PRIORITY_WRITE_SUPPORT}"; printf ',\n'
    printf '    "quota_reset_supported": '; capability_json_bool_or_null "${CAP_QUOTA_RESET_SUPPORT}"; printf ',\n'
    printf '    "routing_strategy_supported": '; capability_json_bool_or_null "${CAP_ROUTING_STRATEGY_SUPPORT}"; printf ',\n'
    printf '    "plugin_system_supported": '; capability_json_bool_or_null "${CAP_PLUGIN_SYSTEM_SUPPORTED}"; printf ',\n'
    printf '    "plugin_system_configured": '; capability_json_bool_or_null "${CAP_PLUGIN_SYSTEM_CONFIGURED}"; printf ',\n'
    printf '    "plugin_system_enabled": '; capability_json_bool_or_null "${CAP_PLUGIN_SYSTEM_ENABLED}"; printf '\n'
    printf '  },\n'
    printf '  "routing": {\n'
    printf '    "strategy": '; capability_json_string_or_null "${CAP_ROUTING_STRATEGY}"; printf ',\n'
    printf '    "weighted_round_robin_supported": '; capability_json_bool_or_null "${CAP_WEIGHTED_ROUND_ROBIN_SUPPORTED}"; printf ',\n'
    printf '    "weighted_round_robin_configured": '; capability_json_bool_or_null "${CAP_WEIGHTED_ROUND_ROBIN_CONFIGURED}"; printf ',\n'
    printf '    "priority_supported": '; capability_json_bool_or_null "${CAP_PRIORITY_SUPPORTED}"; printf ',\n'
    printf '    "priority_configured": '; capability_json_bool_or_null "${CAP_PRIORITY_CONFIGURED}"; printf ',\n'
    printf '    "credential_weights_configured": '; capability_json_bool_or_null "${CAP_CREDENTIAL_WEIGHTS_CONFIGURED}"; printf ',\n'
    printf '    "session_affinity_supported": '; capability_json_bool_or_null "${CAP_SESSION_AFFINITY_SUPPORTED}"; printf ',\n'
    printf '    "session_affinity_enabled": '; capability_json_bool_or_null "${CAP_SESSION_AFFINITY_ENABLED}"; printf ',\n'
    printf '    "session_affinity_ttl": '; capability_json_string_or_null "${CAP_SESSION_AFFINITY_TTL}"; printf ',\n'
    printf '    "automatic_failover_supported": '; capability_json_bool_or_null "${CAP_AUTOMATIC_FAILOVER_SUPPORTED}"; printf ',\n'
    printf '    "wrr_traffic_validation": '; capability_json_string_or_null "${CAP_WRR_TRAFFIC_VALIDATION}"; printf '\n'
    printf '  },\n'
    printf '  "plugins": {\n'
    printf '    "inspection": '; capability_json_string_or_null "${CAP_PLUGIN_INSPECTION}"; printf ',\n'
    printf '    "reason": '; capability_json_string_or_null "${CAP_PLUGIN_INSPECTION_REASON}"; printf ',\n'
    printf '    "source": '; capability_json_string_or_null "${CAP_PLUGIN_SOURCE}"; printf ',\n'
    printf '    "count": '; capability_json_number_or_null "${CAP_PLUGIN_COUNT}"; printf ',\n'
    printf '    "items": ['
    for ((i = 0; i < ${#CAP_PLUGIN_IDS[@]}; i++)); do
        (( i > 0 )) && printf ','
        printf '\n      {"id": '; capability_json_string_or_null "${CAP_PLUGIN_IDS[$i]}"
        printf ', "name": '; capability_json_string_or_null "${CAP_PLUGIN_NAMES[$i]}"
        printf ', "version": '; capability_json_string_or_null "${CAP_PLUGIN_VERSIONS[$i]}"
        printf ', "enabled": '; capability_json_bool_or_null "${CAP_PLUGIN_STATES[$i]}"
        printf ', "menu_count": '; capability_json_number_or_null "${CAP_PLUGIN_MENU_COUNTS[$i]}"; printf '}'
    done
    [[ ${#CAP_PLUGIN_IDS[@]} -gt 0 ]] && printf '\n    '
    printf ']\n'
    printf '  },\n'
    printf '  "security": {\n'
    printf '    "plugin_resource_pages_management_authenticated": '; capability_json_bool_or_null "${CAP_PLUGIN_RESOURCE_MANAGEMENT_AUTHENTICATED}"; printf ',\n'
    printf '    "plugin_resource_pages_verification": '; capability_json_string_or_null "${CAP_PLUGIN_RESOURCE_VERIFICATION}"; printf ',\n'
    printf '    "critical_public_plugin_resource_exposure": '; capability_json_bool_or_null "${CAP_CRITICAL_PUBLIC_PLUGIN_RESOURCE_EXPOSURE}"; printf '\n'
    printf '  },\n'
    printf '  "credentials": {\n'
    printf '    "inspection": '; capability_json_string_or_null "${CAP_CREDENTIAL_INSPECTION}"; printf ',\n'
    printf '    "source": '; capability_json_string_or_null "${CAP_CREDENTIAL_SOURCE}"; printf ',\n'
    printf '    "providers": {\n'
    printf '      "antigravity": '; capability_json_number_or_null "${CAP_CREDENTIAL_ANTIGRAVITY}"; printf ',\n'
    printf '      "claude": '; capability_json_number_or_null "${CAP_CREDENTIAL_CLAUDE}"; printf ',\n'
    printf '      "codex": '; capability_json_number_or_null "${CAP_CREDENTIAL_CODEX}"; printf ',\n'
    printf '      "gemini": '; capability_json_number_or_null "${CAP_CREDENTIAL_GEMINI}"; printf ',\n'
    printf '      "kimi": '; capability_json_number_or_null "${CAP_CREDENTIAL_KIMI}"; printf ',\n'
    printf '      "xai": '; capability_json_number_or_null "${CAP_CREDENTIAL_XAI}"; printf ',\n'
    printf '      "unknown": '; capability_json_number_or_null "${CAP_CREDENTIAL_UNKNOWN}"; printf '\n'
    printf '    },\n'
    printf '    "additional_providers": ['
    for ((i = 0; i < ${#CAP_ADDITIONAL_PROVIDER_TYPES[@]}; i++)); do
        (( i > 0 )) && printf ','
        printf '\n      {"type": '; capability_json_string_or_null "${CAP_ADDITIONAL_PROVIDER_TYPES[$i]}"
        printf ', "count": '; capability_json_number_or_null "${CAP_ADDITIONAL_PROVIDER_COUNTS[$i]}"; printf '}'
    done
    [[ ${#CAP_ADDITIONAL_PROVIDER_TYPES[@]} -gt 0 ]] && printf '\n    '
    printf '],\n'
    printf '    "total": '; capability_json_number_or_null "${CAP_CREDENTIAL_TOTAL}"; printf '\n'
    printf '  },\n'
    printf '  "recovery": {\n'
    printf '    "latest_backup_time": '; capability_json_string_or_null "${CAP_LATEST_BACKUP_TIME}"; printf ',\n'
    printf '    "previous_image_available": '; capability_json_bool_or_null "${CAP_PREVIOUS_IMAGE_AVAILABLE}"; printf '\n'
    printf '  },\n'
    printf '  "warnings": [\n'
    for ((i = 0; i < ${#CAP_FINDING_CODES[@]}; i++)); do
        printf '    {"code": '; capability_json_string_or_null "${CAP_FINDING_CODES[$i]}"
        printf ', "severity": '; capability_json_string_or_null "${CAP_FINDING_SEVERITIES[$i]}"
        printf ', "message": '; capability_json_string_or_null "${CAP_FINDING_MESSAGES[$i]}"
        if (( i + 1 < ${#CAP_FINDING_CODES[@]} )); then printf '},\n'; else printf '}\n'; fi
    done
    printf '  ]\n'
    printf '}\n'
}

cmd_capabilities() {
    local format="${1:-}"
    if [[ $# -gt 1 || ( -n "${format}" && "${format}" != "--json" ) ]]; then
        error "用法: bash deploy.sh capabilities [--json]"
        return 2
    fi

    probe_cpa_capabilities
    if [[ "${format}" == "--json" ]]; then
        render_cpa_capabilities_json
    else
        render_cpa_capabilities_human
    fi
}

resolve_backup_path() {
    local requested="${1:-}"
    if [[ -z "$requested" ]]; then
        printf '%s/backups/cli-proxy-manager-backup-%s.tgz' "${SCRIPT_DIR}" "$(date '+%Y%m%d-%H%M%S')"
    elif [[ "$requested" = /* ]]; then
        printf '%s' "$requested"
    else
        printf '%s/%s' "${SCRIPT_DIR}" "$requested"
    fi
}

get_local_image_digest() {
    docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "${DOCKER_IMAGE}" 2>/dev/null \
        | awk -F@ 'NF > 1 { print $2; exit }'
}

get_remote_image_digest() {
    local digest
    if docker buildx version &>/dev/null; then
        digest="$(docker buildx imagetools inspect "${DOCKER_IMAGE}" --format '{{.Manifest.Digest}}' 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "${digest}" == sha256:* ]]; then
            printf '%s\n' "${digest}"
            return 0
        fi
    fi

    docker manifest inspect --verbose "${DOCKER_IMAGE}" 2>/dev/null \
        | awk -F'"' '/"digest"[[:space:]]*:/ { print $4; exit }'
}

get_image_id() {
    docker image inspect --format '{{.Id}}' "$1" 2>/dev/null | head -1
}

save_current_image_for_rollback() {
    local current_id
    current_id="$(get_image_id "${DOCKER_IMAGE}" || true)"

    if [[ -z "${current_id}" ]]; then
        current_id="$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
    fi

    if [[ -z "${current_id}" ]]; then
        warn "未找到当前镜像，无法创建回滚点"
        return 1
    fi

    docker image tag "${current_id}" "${ROLLBACK_IMAGE}"
    info "已保存更新前镜像"
    detail "回滚镜像: ${ROLLBACK_IMAGE} (${current_id:7:12})"
}

service_health_check_once() {
    sync_api_key_from_config

    if [[ -n "${CPA_API_KEY:-}" ]]; then
        curl -fsS --max-time 5 "http://127.0.0.1:${CPA_PORT}/v1/models" \
            -H "Authorization: Bearer ${CPA_API_KEY}" >/dev/null
        return
    fi

    local http_code
    http_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:${CPA_PORT}/v1/models" 2>/dev/null || true)"
    [[ "${http_code}" == "200" || "${http_code}" == "401" ]]
}

wait_for_service_health() {
    local attempts="${1:-30}"
    local delay="${2:-1}"

    for _ in $(seq 1 "${attempts}"); do
        if service_health_check_once; then
            return 0
        fi
        sleep "${delay}"
    done

    return 1
}

ensure_cpa_cursor_bridge_network() {
    if docker network inspect "${CURSOR_BRIDGE_NETWORK}" >/dev/null 2>&1; then
        return 0
    fi
    docker network create --driver bridge "${CURSOR_BRIDGE_NETWORK}" >/dev/null
}

ensure_cpa_running_after_update_failure() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        return 0
    fi
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        warn "更新失败后未找到 ${CONTAINER_NAME}，无法自动拉起"
        return 1
    fi
    warn "更新失败，正在拉起已有 ${CONTAINER_NAME}，避免服务停机"
    docker start "${CONTAINER_NAME}" >/dev/null
    cursor_bridge_connect_cpa || true
}

recreate_service() {
    cd "${SCRIPT_DIR}"
    ensure_cpa_cursor_bridge_network || return 1
    local rc
    CPA_PORT="${CPA_PORT}" CPA_IMAGE="${DOCKER_IMAGE}" CPA_PULL_POLICY=never \
        $COMPOSE_CMD -f "${COMPOSE_FILE}" up -d --force-recreate
    rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        maybe_start_cursor_bridge_sidecar || true
    fi
    return "${rc}"
}


rollback_saved_image() {
    local previous_current_id
    local rollback_id

    previous_current_id="$(get_image_id "${DOCKER_IMAGE}" || true)"
    rollback_id="$(get_image_id "${ROLLBACK_IMAGE}" || true)"

    if [[ -z "${rollback_id}" ]]; then
        error "没有可用的回滚镜像"
        detail "先成功运行一次 update 或 auto-update，脚本才会保存更新前镜像"
        return 1
    fi

    if [[ "${previous_current_id}" == "${rollback_id}" ]]; then
        warn "当前镜像与回滚镜像相同，无需回滚"
        return 0
    fi

    docker image tag "${rollback_id}" "${DOCKER_IMAGE}"
    if [[ -n "${previous_current_id}" ]]; then
        docker image tag "${previous_current_id}" "${ROLLBACK_IMAGE}"
    fi

    if ! recreate_service >/dev/null; then
        error "回滚容器重建失败"
        if [[ -n "${previous_current_id}" ]]; then
            docker image tag "${previous_current_id}" "${DOCKER_IMAGE}" >/dev/null
        fi
        docker image tag "${rollback_id}" "${ROLLBACK_IMAGE}" >/dev/null
        recreate_service >/dev/null 2>&1 || true
        ensure_cpa_running_after_update_failure || true
        return 1
    fi

    if wait_for_service_health; then
        info "镜像回滚成功"
        detail "当前镜像: ${rollback_id:7:12}"
        return 0
    fi

    error "回滚后的服务健康检查失败，正在恢复回滚前镜像"
    if [[ -n "${previous_current_id}" ]]; then
        docker image tag "${previous_current_id}" "${DOCKER_IMAGE}" >/dev/null
        docker image tag "${rollback_id}" "${ROLLBACK_IMAGE}" >/dev/null
        recreate_service >/dev/null 2>&1 || true
    fi
    ensure_cpa_running_after_update_failure || true
    return 1
}

transactional_update() {
    local rollback_available=false

    if save_current_image_for_rollback; then
        rollback_available=true
    fi

    step "拉取最新镜像"
    detail "${DOCKER_IMAGE}"
    if ! docker pull "${DOCKER_IMAGE}" 2>&1 | tail -1; then
        error "镜像拉取失败；现有服务保持不变"
        return 1
    fi

    step "重建并检查服务"
    local recreate_out recreate_rc=0
    recreate_out="$(recreate_service 2>&1)" || recreate_rc=$?
    if [[ "${recreate_rc}" -ne 0 ]]; then
        error "新容器启动失败"
        if [[ -n "${recreate_out}" ]]; then
            printf '%s\n' "${recreate_out}" | tail -n 30 | sed 's/^/       /'
        fi
        if $rollback_available; then
            warn "正在自动回滚"
            rollback_saved_image || true
        fi
        ensure_cpa_running_after_update_failure || true
        return 1
    fi
    if [[ -n "${recreate_out}" ]]; then
        printf '%s\n' "${recreate_out}" | tail -n 1 | sed 's/^/       /'
    fi

    if wait_for_service_health; then
        info "更新完成，API 健康检查通过"
        detail "手动回滚: bash deploy.sh rollback"
        return 0
    fi

    error "新版本未通过 /v1/models 健康检查"
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" logs --tail 30 || true
    if $rollback_available; then
        warn "正在自动回滚到更新前镜像"
        rollback_saved_image || true
    else
        error "没有更新前镜像，无法自动回滚"
    fi
    ensure_cpa_running_after_update_failure || true
    return 1
}

shell_quote() {
    printf '%q' "$1"
}

ensure_config_file_slot() {
    if [[ ! -d "${CONFIG_FILE}" ]]; then
        return 0
    fi

    warn "检测到 config.yaml 是目录，不是配置文件"
    detail "这通常是先运行 docker compose up，导致 Docker 自动创建了同名目录"

    if find "${CONFIG_FILE}" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        error "config.yaml 目录不是空的，请先手动检查后再处理"
        detail "路径: ${CONFIG_FILE}"
        exit 1
    fi

    if confirm "是否删除这个空目录并重新生成 config.yaml 文件？" "y"; then
        rmdir "${CONFIG_FILE}"
        info "已删除空目录: config.yaml"
    else
        detail "可手动执行: rmdir config.yaml"
        exit 1
    fi
}

require_config_file() {
    if [[ -d "${CONFIG_FILE}" ]]; then
        error "配置路径错误: config.yaml 当前是目录，不是文件"
        detail "请运行: bash deploy.sh"
        detail "或手动执行: rmdir config.yaml && cp config.example.yaml config.yaml"
        exit 1
    fi

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        error "配置文件不存在: ${CONFIG_FILE}"
        detail "请先运行: bash deploy.sh"
        exit 1
    fi
}

config_wizard() {
    step "配置向导"
    echo ""

    ensure_config_file_slot

    # API Key
    local default_key
    default_key="$(generate_key)"
    ask "设置 API 密钥（多个用英文逗号分隔，回车=随机生成）" "${default_key}"
    read -r input_key
    parse_api_keys "${input_key}" "${default_key}"
    if [[ ${#API_KEYS[@]} -eq 1 ]]; then
        info "API 密钥: ${CYAN}${CPA_API_KEY}${NC}"
    else
        info "API 密钥: ${CYAN}共 ${#API_KEYS[@]} 个${NC}"
    fi

    # Port
    ask "服务端口" "${CPA_PORT}"
    read -r input_port
    CPA_PORT="${input_port:-$CPA_PORT}"
    info "服务端口: ${CYAN}${CPA_PORT}${NC}"

    # Management panel
    if confirm "是否启用管理面板？" "y"; then
        local default_mgmt_key
        default_mgmt_key="$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 16 || :)"
        ask "管理面板密码" "${default_mgmt_key}"
        read -r input_mgmt
        CPA_MANAGEMENT_KEY="${input_mgmt:-$default_mgmt_key}"
        info "管理面板: ${GREEN}启用${NC}"
    else
        CPA_MANAGEMENT_KEY=""
        info "管理面板: ${DIM}禁用${NC}"
    fi

    # Debug mode
    local debug_mode="false"
    if confirm "是否开启调试日志？(首次部署建议开启)" "y"; then
        debug_mode="true"
    fi

    # File logging (logging-to-file)
    local logging_mode="false"
    if confirm "是否开启文件日志？(logging-to-file，便于在面板 Logs 页查看)" "y"; then
        logging_mode="true"
    fi

    # Plugin system (plugins.enabled)
    local plugins_mode="false"
    if confirm "是否启用插件系统？(plugins.enabled，安装插件后才会生效)" "y"; then
        plugins_mode="true"
    fi

    divider

    # Generate config.yaml
    local api_keys_yaml=""
    local api_key
    for api_key in "${API_KEYS[@]}"; do
        [[ -n "$api_keys_yaml" ]] && api_keys_yaml+=$'\n'
        api_keys_yaml+="  - \"$(yaml_quote "$api_key")\""
    done

    cat > "${CONFIG_FILE}" << YAML
# =============================================================================
#  CLI Proxy Manager 配置文件
#  由 deploy.sh 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

host: ""
port: 8317

auth-dir: "/root/.cli-proxy-api"

api-keys:
${api_keys_yaml}

debug: ${debug_mode}

usage-statistics-enabled: true
logging-to-file: ${logging_mode}

request-retry: 3
max-retry-interval: 30

quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true

routing:
  strategy: "round-robin"

streaming:
  keepalive-seconds: 15
  bootstrap-retries: 1

nonstream-keepalive-interval: 30

remote-management:
  allow-remote: false
  secret-key: "${CPA_MANAGEMENT_KEY}"
  disable-control-panel: false

plugins:
  enabled: ${plugins_mode}
  dir: "plugins"
YAML

    info "配置文件已生成: ${CYAN}config.yaml${NC}"
}

# ========================== 核心操作 ==========================================

pull_image() {
    step "拉取最新镜像"
    detail "${DOCKER_IMAGE}"

    if docker pull "${DOCKER_IMAGE}" 2>&1 | tail -1; then
        info "镜像已就绪"
    else
        error "镜像拉取失败，请检查网络"
        exit 1
    fi
}

do_login() {
    local provider="${1:-antigravity}"
    local login_flag
    local auth_pattern
    local oauth_port="${OAUTH_PORT}"
    step "OAuth 登录 — ${provider}"

    case "${provider}" in
        antigravity) login_flag="-antigravity-login"; auth_pattern="antigravity*" ;;
        claude)      login_flag="-claude-login"; auth_pattern="claude*" ;;
        gemini)      login_flag="-login"; auth_pattern="*.json" ;;
        codex)       login_flag="-codex-login"; auth_pattern="codex*"; oauth_port=1455 ;;
        *)
            error "不支持的 Provider: ${provider}"
            exit 1
            ;;
    esac

    require_config_file

    # 检查已有凭证
    if docker volume inspect "${AUTH_VOLUME}" &>/dev/null 2>&1; then
        local auth_check
        auth_check=$(docker run --rm -v "${AUTH_VOLUME}:/auth" alpine \
            sh -c "find /auth -name '${auth_pattern}' 2>/dev/null | head -1" 2>/dev/null || echo "")
        if [[ -n "$auth_check" ]]; then
            warn "检测到已有 ${provider} 凭证"
            if ! confirm "是否重新登录覆盖？" "n"; then
                info "保留已有凭证，跳过登录"
                return 0
            fi
        fi
    fi

    echo ""
    echo -e "     ${YELLOW}即将生成 OAuth 登录链接${NC}"
    echo -e "     ${YELLOW}本次 OAuth 回调端口: ${oauth_port}${NC}"
    echo -e "     ${YELLOW}请复制终端中的链接到浏览器完成授权，然后回到终端${NC}"
    echo ""

    if ! confirm "准备好了吗？" "y"; then
        warn "跳过登录（稍后可通过 ${CYAN}bash deploy.sh login${NC} 补充登录）"
        return 0
    fi

    if ! docker run --rm -it \
        -p "${oauth_port}:${oauth_port}" \
        -v "${CONFIG_FILE}:/CLIProxyAPI/config.yaml" \
        -v "${AUTH_VOLUME}:/root/.cli-proxy-api" \
        "${DOCKER_IMAGE}" \
        ./CLIProxyAPI \
        -config /CLIProxyAPI/config.yaml \
        "${login_flag}" \
        -oauth-callback-port "${oauth_port}" \
        -no-browser; then
        warn "登录命令未完成（可稍后重试: ${CYAN}bash deploy.sh login${NC}）"
        return 1
    fi

    local saved_auth
    saved_auth=$(docker run --rm -v "${AUTH_VOLUME}:/auth" alpine \
        sh -c "find /auth -name '${auth_pattern}' 2>/dev/null | head -1" 2>/dev/null || echo "")
    if [[ -z "${saved_auth}" ]]; then
        warn "未检测到 ${provider} 凭证文件，请确认浏览器授权是否完成"
        return 1
    fi

    info "${provider} 登录成功"
}

do_logout() {
    local provider="${1:-}"
    local auth_pattern
    local display_name

    case "${provider}" in
        antigravity) auth_pattern="antigravity*"; display_name="Antigravity" ;;
        claude)      auth_pattern="claude*"; display_name="Claude Code" ;;
        gemini)      auth_pattern="*.json"; display_name="Gemini CLI" ;;
        codex)       auth_pattern="codex*"; display_name="Codex" ;;
        all)         auth_pattern=""; display_name="所有 Provider" ;;
        *)
            error "不支持的 Provider: ${provider}"
            exit 1
            ;;
    esac

    # 检查凭证卷是否存在
    if ! docker volume inspect "${AUTH_VOLUME}" &>/dev/null 2>&1; then
        warn "未找到凭证存储卷，没有需要退出的账号"
        return 0
    fi

    # 列出匹配的凭证文件
    local cred_files
    if [[ "${provider}" == "all" ]]; then
        cred_files=$(docker run --rm -v "${AUTH_VOLUME}:/auth" alpine \
            sh -c "find /auth -maxdepth 1 -type f 2>/dev/null | grep -Ev '/(config|logs)$' | sed 's|/auth/||'" 2>/dev/null || echo "")
    else
        cred_files=$(docker run --rm -v "${AUTH_VOLUME}:/auth" alpine \
            sh -c "find /auth -maxdepth 1 -name '${auth_pattern}' -type f 2>/dev/null | sed 's|/auth/||'" 2>/dev/null || echo "")
    fi

    if [[ -z "${cred_files}" ]]; then
        warn "未检测到 ${display_name} 的凭证文件"
        return 0
    fi

    echo ""
    echo -e "     ${YELLOW}将要删除以下 ${display_name} 凭证文件:${NC}"
    echo "${cred_files}" | while IFS= read -r f; do
        echo -e "       ${DIM}• ${f}${NC}"
    done
    echo ""

    if ! confirm "确认退出 ${display_name} 账号？" "n"; then
        info "取消操作"
        return 0
    fi

    # 删除凭证文件
    if [[ "${provider}" == "all" ]]; then
        docker run --rm -v "${AUTH_VOLUME}:/auth" alpine \
            sh -c "find /auth -maxdepth 1 -type f | grep -Ev '/(config|logs)$' | xargs rm -f" 2>/dev/null
    else
        docker run --rm -v "${AUTH_VOLUME}:/auth" alpine \
            sh -c "find /auth -maxdepth 1 -name '${auth_pattern}' -type f -exec rm -f {} +" 2>/dev/null
    fi

    info "${display_name} 凭证已删除"
}

start_service() {
    step "启动代理服务"

    require_config_file
    sync_api_key_from_config

    cd "${SCRIPT_DIR}"

    # 停止已有容器
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        detail "停止旧容器..."
        CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" down 2>/dev/null || true
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            detail "清理旧项目遗留容器..."
            docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        fi
    fi

    ensure_cpa_cursor_bridge_network || {
        error "无法创建 ${CURSOR_BRIDGE_NETWORK}"
        return 1
    }

    # 镜像已在停止旧容器前拉取，避免 Compose 重复访问仓库
    CPA_PORT="${CPA_PORT}" CPA_IMAGE="${DOCKER_IMAGE}" CPA_PULL_POLICY=never \
        $COMPOSE_CMD -f "${COMPOSE_FILE}" up -d 2>&1 | tail -1


    # 等待就绪
    echo -en "     等待服务就绪 "
    local ready=false
    for _ in $(seq 1 20); do
        if curl -sf "http://127.0.0.1:${CPA_PORT}/v1/models" \
            -H "Authorization: Bearer ${CPA_API_KEY:-dummy}" &>/dev/null; then
            ready=true
            break
        fi
        echo -n "·"
        sleep 1
    done
    echo ""

    if $ready; then
        info "服务已启动并响应正常"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        info "容器已运行（API 响应可能需等待 OAuth 凭证生效）"
    else
        error "启动失败，查看日志:"
        CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" logs --tail 30
        exit 1
    fi
}

# ========================== 显示最终信息 ======================================

show_result() {
    sync_api_key_from_config
    local key_count
    key_count="$(config_api_key_count)"

    echo ""
    echo -e "  ${GREEN}${BOLD}🎉 部署完成！${NC}"
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}服务信息${NC}"
    echo -e "  代理地址  ${GREEN}http://127.0.0.1:${CPA_PORT}${NC}"
    if [[ "${key_count:-0}" -gt 1 ]]; then
        echo -e "  API 密钥  ${GREEN}${CPA_API_KEY}${NC} ${DIM}(共 ${key_count} 个)${NC}"
    else
        echo -e "  API 密钥  ${GREEN}${CPA_API_KEY}${NC}"
    fi
    if [[ -n "${CPA_MANAGEMENT_KEY}" ]]; then
        echo -e "  管理面板  ${GREEN}http://127.0.0.1:${CPA_PORT}/management.html${NC}"
        echo -e "  面板密码  ${DIM}已设置（不回显）${NC}"
    fi
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}Claude Code for VS Code 配置${NC}"
    echo ""
    echo -e "  在 VS Code ${CYAN}settings.json${NC} 中添加:"
    echo ""
    echo -e "  ${DIM}// settings.json${NC}"
    echo -e "  ${GREEN}{${NC}"
    echo -e "  ${GREEN}  \"claude-code.env\": {${NC}"
    echo -e "  ${GREEN}    \"ANTHROPIC_BASE_URL\": \"http://127.0.0.1:${CPA_PORT}\",${NC}"
    echo -e "  ${GREEN}    \"ANTHROPIC_AUTH_TOKEN\": \"${CPA_API_KEY}\"${NC}"
    echo -e "  ${GREEN}  }${NC}"
    echo -e "  ${GREEN}}${NC}"
    echo ""
    echo -e "  ${DIM}或在 ~/.zshrc 中添加:${NC}"
    echo ""
    echo -e "  ${GREEN}export ANTHROPIC_BASE_URL=\"http://127.0.0.1:${CPA_PORT}\"${NC}"
    echo -e "  ${GREEN}export ANTHROPIC_AUTH_TOKEN=\"${CPA_API_KEY}\"${NC}"
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}常用命令${NC}"
    echo -e "  ${CYAN}bash deploy.sh status${NC}     查看服务状态"
    echo -e "  ${CYAN}bash deploy.sh logs${NC}       查看实时日志"
    echo -e "  ${CYAN}bash deploy.sh restart${NC}    重启服务"
    echo -e "  ${CYAN}bash deploy.sh stop${NC}       停止服务"
    echo -e "  ${CYAN}bash deploy.sh doctor${NC}     自检诊断"
    echo -e "  ${CYAN}bash deploy.sh backup${NC}     备份配置和 OAuth 凭证"
    echo -e "  ${CYAN}bash deploy.sh check-update${NC} 检查镜像更新"
    echo -e "  ${CYAN}bash deploy.sh update${NC}     安全更新到最新版本"
    echo -e "  ${CYAN}bash deploy.sh rollback${NC}   回滚到上一个镜像版本"
    echo -e "  ${CYAN}bash deploy.sh login${NC}      重新 OAuth 登录"
    echo -e "  ${CYAN}bash deploy.sh logout${NC}     退出 Provider 账号"
    echo -e "  ${CYAN}bash deploy.sh setup-claude${NC} 自动配置 Claude Code"
    echo -e "  ${CYAN}bash deploy.sh uninstall${NC}  完全卸载"
    echo ""
}

# ========================== 子命令实现 ========================================

cmd_deploy() {
    banner
    check_prereqs

    if [[ -f "${CONFIG_FILE}" ]]; then
        step "检测到已有 config.yaml"
        echo -e "  ${CYAN}1)${NC} 重新配置（覆盖现有 config 与全部 key）"
        echo -e "  ${CYAN}2)${NC} 保留并仅启动"
        echo ""
        ask "选择" "2"
        read -r config_choice
        config_choice="${config_choice:-2}"

        if [[ "${config_choice}" != "1" ]]; then
            info "保留现有配置，仅启动服务"
            start_service
            maybe_start_cursor_bridge_sidecar || true
            show_result
            return 0
        fi

        warn "将覆盖现有 config.yaml 与全部 API key"
    fi

    config_wizard

    echo ""

    echo -e "  ${BOLD}选择要登录的 Provider${NC}"
    echo -e "  ${DIM}(CLIProxyAPI 支持多种 Provider，可后续追加)${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Antigravity    ${DIM}(Google DeepMind)${NC}"
    echo -e "  ${CYAN}2)${NC} Claude Code    ${DIM}(Anthropic)${NC}"
    echo -e "  ${CYAN}3)${NC} Gemini CLI     ${DIM}(Google)${NC}"
    echo -e "  ${CYAN}4)${NC} Codex          ${DIM}(OpenAI)${NC}"
    echo -e "  ${CYAN}5)${NC} 跳过登录      ${DIM}(稍后手动登录)${NC}"
    echo ""
    ask "选择" "1"
    read -r provider_choice
    provider_choice="${provider_choice:-1}"

    case "$provider_choice" in
        1) do_login "antigravity" ;;
        2) do_login "claude" ;;
        3) do_login "gemini" ;;
        4) do_login "codex" ;;
        5) warn "跳过登录（稍后通过 bash deploy.sh login 补充）" ;;
        *) do_login "antigravity" ;;
    esac

    start_service
    maybe_start_cursor_bridge_sidecar || true
    show_result
}

cmd_login() {
    banner
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }
    require_config_file

    echo ""
    echo -e "  ${BOLD}选择要登录的 Provider${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Antigravity    ${DIM}(Google DeepMind)${NC}"
    echo -e "  ${CYAN}2)${NC} Claude Code    ${DIM}(Anthropic)${NC}"
    echo -e "  ${CYAN}3)${NC} Gemini CLI     ${DIM}(Google)${NC}"
    echo -e "  ${CYAN}4)${NC} Codex          ${DIM}(OpenAI)${NC}"
    echo ""
    ask "选择" "1"
    read -r choice
    choice="${choice:-1}"

    case "$choice" in
        1) do_login "antigravity" ;;
        2) do_login "claude" ;;
        3) do_login "gemini" ;;
        4) do_login "codex" ;;
        *) do_login "antigravity" ;;
    esac

    # 重启服务（如果正在运行）
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        if confirm "服务正在运行，是否立即重启以应用新凭证？" "y"; then
            cd "${SCRIPT_DIR}"
            CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" restart 2>&1 | tail -1
            info "服务已重启"
        fi
    fi
}

cmd_logout() {
    banner
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }

    # 检查凭证卷
    if ! docker volume inspect "${AUTH_VOLUME}" &>/dev/null 2>&1; then
        warn "未找到凭证存储卷，没有已登录的账号"
        return 0
    fi

    # 显示当前凭证状态
    step "当前已登录凭证"
    local cred_info
    cred_info=$(docker run --rm -v "${AUTH_VOLUME}:/auth" alpine \
        sh -c "ls /auth/ 2>/dev/null | grep -Ev '^(config|logs)$' | tr '\\n' ' '" 2>/dev/null || echo "")
    if [[ -z "${cred_info}" ]]; then
        warn "当前没有已登录的账号"
        return 0
    fi
    echo -e "     ${DIM}${cred_info}${NC}"

    echo ""
    echo -e "  ${BOLD}选择要退出的 Provider${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Antigravity    ${DIM}(Google DeepMind)${NC}"
    echo -e "  ${CYAN}2)${NC} Claude Code    ${DIM}(Anthropic)${NC}"
    echo -e "  ${CYAN}3)${NC} Gemini CLI     ${DIM}(Google)${NC}"
    echo -e "  ${CYAN}4)${NC} Codex          ${DIM}(OpenAI)${NC}"
    echo -e "  ${CYAN}5)${NC} 全部退出      ${DIM}(清除所有凭证)${NC}"
    echo ""
    ask "选择" "1"
    read -r choice
    choice="${choice:-1}"

    case "$choice" in
        1) do_logout "antigravity" ;;
        2) do_logout "claude" ;;
        3) do_logout "gemini" ;;
        4) do_logout "codex" ;;
        5) do_logout "all" ;;
        *) do_logout "antigravity" ;;
    esac

    # 重启服务（如果正在运行）
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        if confirm "服务正在运行，是否立即重启以应用变更？" "y"; then
            cd "${SCRIPT_DIR}"
            CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" restart 2>&1 | tail -1
            info "服务已重启"
        fi
    fi
}

cmd_start() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }

    # 尝试从现有 config 读取 API key
    sync_api_key_from_config

    start_service
    maybe_start_cursor_bridge_sidecar || true

    echo ""
    info "代理地址: ${GREEN}http://127.0.0.1:${CPA_PORT}${NC}"
}

cmd_stop() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }
    cd "${SCRIPT_DIR}"
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" down 2>&1 | tail -1
    info "服务已停止"
}

cmd_restart() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }
    cd "${SCRIPT_DIR}"
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" restart 2>&1 | tail -1
    info "服务已重启"
    cursor_bridge_connect_cpa || true
}

cmd_status() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }

    echo ""
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        info "服务状态: ${GREEN}运行中${NC}"
        echo ""
        docker ps --filter "name=${CONTAINER_NAME}" \
            --format "     容器: {{.Names}}  |  状态: {{.Status}}  |  端口: {{.Ports}}"
        echo ""

        # 尝试从现有 config 读取 API key 和 port
        sync_api_key_from_config

        # 从容器端口映射获取实际端口
        local mapped_port
        mapped_port=$(docker port "${CONTAINER_NAME}" 8317/tcp 2>/dev/null | head -1 | cut -d: -f2 || echo "${CPA_PORT}")
        CPA_PORT="${mapped_port:-$CPA_PORT}"

        echo -n "     API 测试: "
        local http_code
        http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
            "http://127.0.0.1:${CPA_PORT}/v1/models" \
            -H "Authorization: Bearer ${CPA_API_KEY:-dummy}" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            echo -e "${GREEN}正常 (${http_code})${NC}"
        elif [[ "$http_code" == "401" ]]; then
            echo -e "${YELLOW}认证失败 (${http_code}) — 请检查 API Key${NC}"
        elif [[ "$http_code" == "000" ]]; then
            echo -e "${YELLOW}无响应 — 服务可能仍在初始化${NC}"
        else
            echo -e "${YELLOW}异常 (${http_code})${NC}"
        fi

        # 凭证检查
        echo ""
        echo -n "     已登录凭证: "
        local cred_info
        cred_info=$(docker run --rm -v "${AUTH_VOLUME}:/auth" alpine \
            sh -c "ls /auth/ 2>/dev/null | grep -Ev '^(config|logs)$' | tr '\\n' ' '" 2>/dev/null || echo "无")
        echo -e "${DIM}${cred_info:-无}${NC}"
    else
        warn "服务未运行"
        detail "使用 ${CYAN}bash deploy.sh start${NC} 启动"
    fi
    echo ""
}

cmd_logs() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }
    cd "${SCRIPT_DIR}"
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" logs -f --tail 100
}

cmd_doctor() {
    banner
    step "Doctor v2 read-only check"

    probe_cpa_capabilities

    local failures=0 warnings=0 i

    [[ "${CAP_DOCKER_CLI}" == "true" ]] && info "Docker CLI is available"
    [[ "${CAP_DOCKER_DAEMON}" == "true" ]] && info "Docker daemon is available"
    [[ "${CAP_COMPOSE_AVAILABLE}" == "true" ]] && info "Docker Compose is available (${COMPOSE_CMD})"
    if [[ "${CAP_CONFIG_STATE}" == "file" ]]; then
        info "config.yaml is a file; API key count: $(capability_display_value "${CAP_CONFIG_API_KEY_COUNT}")"
    fi
    [[ "${CAP_COMPOSE_VALID}" == "true" ]] && info "docker-compose.yml is valid"
    [[ "${CAP_CONTAINER_RUNNING}" == "true" ]] && info "CPA container is running: ${CONTAINER_NAME}"

    info "Configured binding: ${CAP_CONFIGURED_BIND_ADDRESS}:$(capability_display_value "${CAP_CONFIGURED_BIND_PORT}")"
    if [[ "${CAP_ACTUAL_BIND_ADDRESS}" != "unknown" ]]; then
        info "Actual binding: ${CAP_ACTUAL_BIND_ADDRESS}:$(capability_display_value "${CAP_ACTUAL_BIND_PORT}")"
    fi
    info "Exposure mode: $(capability_display_value "${CAP_EXPOSURE_MODE}")"

    if [[ "${CAP_IMAGE_LOCAL_ID}" != "unknown" ]]; then
        info "CPA image is available locally"
        detail "Reference: ${CAP_IMAGE_REFERENCE}"
        detail "Image ID: ${CAP_IMAGE_LOCAL_ID}"
        detail "Repository digest: $(capability_display_value "${CAP_IMAGE_REPOSITORY_DIGEST}")"
    fi
    if [[ "${CAP_CPA_VERSION}" != "unknown" || "${CAP_CPA_COMMIT}" != "unknown" ]]; then
        info "CPA build metadata is available"
        detail "Version: $(capability_display_value "${CAP_CPA_VERSION}")"
        detail "Commit: $(capability_display_value "${CAP_CPA_COMMIT}")"
    else
        info "CPA build metadata is unavailable from the local API"
    fi
    info "D2.2 release contract: CPA ${RELEASE_CONTRACT_CPA_VERSION}@${RELEASE_CONTRACT_CPA_COMMIT}, Management Center ${RELEASE_CONTRACT_MANAGEMENT_CENTER_VERSION}@${RELEASE_CONTRACT_MANAGEMENT_CENTER_COMMIT}"
    detail "contract-source=exact_release_tags, target-pair-compatible=yes, runtime-compatibility=$(capability_display_value "${CAP_RELEASE_COMPATIBILITY_STATUS}")"

    if [[ "${CAP_API_HEALTHY}" == "true" ]]; then
        info "CPA API is healthy"
    fi
    if [[ "${CAP_MODELS_HTTP_STATUS}" == "200" ]]; then
        info "/v1/models returned 200; model count: $(capability_display_value "${CAP_MODEL_COUNT}")"
    fi

    info "Remote management: configured=$(capability_display_bool "${CAP_REMOTE_CONFIGURED}"), allow_remote=$(capability_display_bool "${CAP_REMOTE_ALLOW}"), panel_disabled=$(capability_display_bool "${CAP_REMOTE_PANEL_DISABLED}"), secret_configured=$(capability_display_bool "${CAP_REMOTE_SECRET_CONFIGURED}")"
    info "Management UI: enabled=$(capability_display_bool "${CAP_MANAGEMENT_UI_ENABLED}"), reachable=$(capability_display_bool "${CAP_MANAGEMENT_UI_REACHABLE}"), HTTP=$(capability_display_value "${CAP_MANAGEMENT_UI_HTTP_STATUS}")"
    detail "Management Center version=$(capability_display_value "${CAP_MANAGEMENT_UI_VERSION}"), source=$(capability_display_value "${CAP_MANAGEMENT_UI_VERSION_SOURCE}")"
    detail "Safe local URL: $(capability_display_value "${CAP_MANAGEMENT_UI_LOCAL_URL}")"
    detail "External HTTPS protection: $(capability_display_bool "${CAP_MANAGEMENT_UI_EXTERNAL_HTTPS}")"
    info "Official Management API support: $(capability_display_bool "${CAP_MANAGEMENT_API_AVAILABLE}") (contract=$(capability_display_value "${CAP_OFFICIAL_CONTRACT_SOURCE}"))"
    detail "auth-files=$(capability_display_bool "${CAP_AUTH_FILES_INVENTORY_SUPPORT}"), account-status=$(capability_display_bool "${CAP_ACCOUNT_STATUS_SUPPORT}"), priority-read=$(capability_display_bool "${CAP_PRIORITY_READ_SUPPORT}"), priority-write=$(capability_display_bool "${CAP_PRIORITY_WRITE_SUPPORT}")"
    detail "quota-reset=$(capability_display_bool "${CAP_QUOTA_RESET_SUPPORT}"), routing-strategy=$(capability_display_bool "${CAP_ROUTING_STRATEGY_SUPPORT}")"
    info "Routing: strategy=$(capability_display_value "${CAP_ROUTING_STRATEGY}"), weighted-supported=$(capability_display_bool "${CAP_WEIGHTED_ROUND_ROBIN_SUPPORTED}"), weighted-configured=$(capability_display_bool "${CAP_WEIGHTED_ROUND_ROBIN_CONFIGURED}")"
    detail "priority-supported=$(capability_display_bool "${CAP_PRIORITY_SUPPORTED}"), priority-configured=$(capability_display_bool "${CAP_PRIORITY_CONFIGURED}"), credential-weights-configured=$(capability_display_bool "${CAP_CREDENTIAL_WEIGHTS_CONFIGURED}")"
    detail "session-affinity-supported=$(capability_display_bool "${CAP_SESSION_AFFINITY_SUPPORTED}"), enabled=$(capability_display_bool "${CAP_SESSION_AFFINITY_ENABLED}"), ttl=$(capability_display_value "${CAP_SESSION_AFFINITY_TTL}"), automatic-failover=$(capability_display_bool "${CAP_AUTOMATIC_FAILOVER_SUPPORTED}"), WRR-traffic-validation=${CAP_WRR_TRAFFIC_VALIDATION}"
    info "CPA plugin system: supported=$(capability_display_bool "${CAP_PLUGIN_SYSTEM_SUPPORTED}"), configured=$(capability_display_bool "${CAP_PLUGIN_SYSTEM_CONFIGURED}"), enabled=$(capability_display_bool "${CAP_PLUGIN_SYSTEM_ENABLED}")"
    if [[ "${CAP_PLUGIN_INSPECTION}" == "available" ]]; then
        detail "Installed plugin count: ${CAP_PLUGIN_COUNT}"
    else
        detail "Plugin inspection unavailable: $(capability_display_value "${CAP_PLUGIN_INSPECTION_REASON}")"
    fi
    detail "Plugin resource pages use management authentication: $(capability_display_bool "${CAP_PLUGIN_RESOURCE_MANAGEMENT_AUTHENTICATED}")"
    if [[ "${CAP_CREDENTIAL_INSPECTION}" == "available" ]]; then
        info "Provider credential counts are available"
        detail "source=${CAP_CREDENTIAL_SOURCE}, antigravity=${CAP_CREDENTIAL_ANTIGRAVITY}, claude=${CAP_CREDENTIAL_CLAUDE}, codex=${CAP_CREDENTIAL_CODEX}, gemini=${CAP_CREDENTIAL_GEMINI}, kimi=${CAP_CREDENTIAL_KIMI}, xai=${CAP_CREDENTIAL_XAI}, unknown=${CAP_CREDENTIAL_UNKNOWN}, total=${CAP_CREDENTIAL_TOTAL}"
    fi
    if [[ "${CAP_LATEST_BACKUP_TIME}" != "unknown" ]]; then
        info "Latest CPA backup: ${CAP_LATEST_BACKUP_TIME}"
    fi
    [[ "${CAP_PREVIOUS_IMAGE_AVAILABLE}" == "true" ]] && info "Previous-image recovery target is available"

    for ((i = 0; i < ${#CAP_FINDING_CODES[@]}; i++)); do
        case "${CAP_FINDING_SEVERITIES[$i]}" in
            failure)
                error "${CAP_FINDING_CODES[$i]}: ${CAP_FINDING_MESSAGES[$i]}"
                failures=$((failures + 1))
                ;;
            critical)
                warn "CRITICAL ${CAP_FINDING_CODES[$i]}: ${CAP_FINDING_MESSAGES[$i]}"
                warnings=$((warnings + 1))
                ;;
            *)
                warn "${CAP_FINDING_CODES[$i]}: ${CAP_FINDING_MESSAGES[$i]}"
                warnings=$((warnings + 1))
                ;;
        esac
    done

    echo ""
    divider
    if [[ ${failures} -eq 0 ]]; then
        info "Doctor v2 completed: ${warnings} warning(s), 0 failure(s)"
    else
        error "Doctor v2 completed: ${warnings} warning(s), ${failures} failure(s)"
        return 1
    fi
}

cmd_backup() {
    local dest
    dest="$(resolve_backup_path "${1:-}")"

    if [[ -e "${dest}" ]] && ! confirm "备份文件已存在，是否覆盖？" "n"; then
        info "取消备份"
        return 0
    fi

    mkdir -p "$(dirname "${dest}")"

    local has_config=false
    local has_auth=false
    [[ -f "${CONFIG_FILE}" ]] && has_config=true
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1 && docker volume inspect "${AUTH_VOLUME}" &>/dev/null 2>&1; then
        has_auth=true
    fi

    if ! $has_config && ! $has_auth; then
        error "没有找到 config.yaml 或 OAuth 凭证卷，无法备份"
        return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"

    if $has_config; then
        cp "${CONFIG_FILE}" "${tmpdir}/config.yaml"
    else
        warn "未找到 config.yaml，本次仅备份凭证卷"
    fi

    if $has_auth; then
        mkdir -p "${tmpdir}/auth"
        docker run --rm \
            -v "${AUTH_VOLUME}:/auth:ro" \
            -v "${tmpdir}/auth:/backup-auth" \
            alpine sh -c 'cp -a /auth/. /backup-auth/ 2>/dev/null || true' >/dev/null
    else
        warn "未找到 OAuth 凭证卷，本次仅备份 config.yaml"
    fi

    tar -czf "${dest}" -C "${tmpdir}" .
    chmod 600 "${dest}" 2>/dev/null || true

    rm -rf "${tmpdir}"

    info "备份已创建: ${CYAN}${dest}${NC}"
    detail "包含 config.yaml 和 OAuth 凭证卷（如存在）"
}

cmd_restore() {
    local source_file="${1:-}"
    if [[ -z "${source_file}" ]]; then
        error "缺少备份文件"
        detail "用法: bash deploy.sh restore backups/cli-proxy-manager-backup-YYYYmmdd-HHMMSS.tgz"
        return 1
    fi
    [[ "${source_file}" = /* ]] || source_file="${SCRIPT_DIR}/${source_file}"

    if [[ ! -f "${source_file}" ]]; then
        error "备份文件不存在: ${source_file}"
        return 1
    fi

    warn "恢复会覆盖当前 config.yaml 和 OAuth 凭证卷"
    if ! confirm "确认恢复？" "n"; then
        info "取消恢复"
        return 0
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    tar -xzf "${source_file}" -C "${tmpdir}"

    if [[ ! -f "${tmpdir}/config.yaml" && ! -d "${tmpdir}/auth" ]]; then
        error "备份文件格式不正确"
        rm -rf "${tmpdir}"
        return 1
    fi

    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        if confirm "服务正在运行，是否先停止再恢复？" "y"; then
            docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
            info "服务已停止"
        else
            warn "服务仍在运行，恢复后建议手动重启"
        fi
    fi

    if [[ -f "${tmpdir}/config.yaml" ]]; then
        if [[ -d "${CONFIG_FILE}" ]]; then
            if find "${CONFIG_FILE}" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
                error "config.yaml 是非空目录，未覆盖"
                rm -rf "${tmpdir}"
                return 1
            fi
            rmdir "${CONFIG_FILE}"
        fi
        cp "${tmpdir}/config.yaml" "${CONFIG_FILE}"
        chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
        info "config.yaml 已恢复"
    fi

    if [[ -d "${tmpdir}/auth" ]]; then
        if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
            error "Docker 不可用，无法恢复 OAuth 凭证卷"
            rm -rf "${tmpdir}"
            return 1
        fi
        docker volume create "${AUTH_VOLUME}" >/dev/null
        docker run --rm \
            -v "${AUTH_VOLUME}:/auth" \
            -v "${tmpdir}/auth:/restore-auth:ro" \
            alpine sh -c 'rm -rf /auth/* /auth/.[!.]* /auth/..?* 2>/dev/null || true; cp -a /restore-auth/. /auth/ 2>/dev/null || true' >/dev/null
        info "OAuth 凭证卷已恢复"
    fi

    rm -rf "${tmpdir}"

    info "恢复完成"
    detail "可运行: bash deploy.sh start"
}

cmd_check_update() {
    step "检查镜像更新"
    detail "${DOCKER_IMAGE}"

    if ! command -v docker &>/dev/null; then
        error "未检测到 Docker CLI"
        return 1
    fi

    local remote_digest
    remote_digest="$(get_remote_image_digest || true)"
    if [[ -z "${remote_digest}" ]]; then
        warn "无法获取远端镜像信息（网络或 registry 限制）"
        return 1
    fi

    local local_digest
    local_digest="$(get_local_image_digest || true)"
    if [[ -z "${local_digest}" ]]; then
        warn "本地尚未找到镜像，请运行 ${CYAN}bash deploy.sh update${NC}"
        detail "远端 digest: ${remote_digest}"
        return 0
    fi

    if [[ "${local_digest}" == "${remote_digest}" ]]; then
        info "当前镜像已是最新"
        detail "digest: ${local_digest}"
    else
        warn "发现新镜像，可运行 ${CYAN}bash deploy.sh update${NC}"
        detail "本地: ${local_digest}"
        detail "远端: ${remote_digest}"
    fi
}

cmd_update() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }
    require_config_file

    step "更新到最新版本"
    if transactional_update; then
        rm -f "${FAILED_UPDATE_FILE}"
    else
        return 1
    fi
}

cmd_rollback() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }
    require_config_file

    step "回滚 Docker 镜像"
    detail "${ROLLBACK_IMAGE}"
    local rejected_digest
    rejected_digest="$(get_local_image_digest || true)"
    if rollback_saved_image; then
        if [[ -n "${rejected_digest}" ]]; then
            mkdir -p "$(dirname "${FAILED_UPDATE_FILE}")"
            printf '%s\n' "${rejected_digest}" > "${FAILED_UPDATE_FILE}"
            detail "自动更新将跳过刚回滚的 digest，直到远端版本变化"
        fi
    else
        return 1
    fi
}

cmd_auto_update() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }
    require_config_file

    local update_trigger="${CPA_UPDATE_TRIGGER:-manual}"
    local trigger_label="手动执行"
    [[ "${update_trigger}" == "cron" ]] && trigger_label="cron 定时任务"

    step "自动更新检查"
    detail "${DOCKER_IMAGE}"
    detail "触发来源: ${update_trigger}（${trigger_label}）"
    detail "服务器时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    detail "北京时间: $(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %Z')"

    if ! command -v docker &>/dev/null; then
        error "未检测到 Docker CLI"
        return 1
    fi

    local remote_digest
    remote_digest="$(get_remote_image_digest || true)"
    if [[ -z "${remote_digest}" ]]; then
        warn "无法获取远端镜像信息（网络或 registry 限制）"
        return 1
    fi

    local failed_digest=""
    if [[ -f "${FAILED_UPDATE_FILE}" ]]; then
        failed_digest="$(tr -d '[:space:]' < "${FAILED_UPDATE_FILE}" || true)"
    fi
    if [[ -n "${failed_digest}" && "${failed_digest}" == "${remote_digest}" ]]; then
        warn "远端镜像上次未通过健康检查，本次跳过"
        detail "失败 digest: ${failed_digest}"
        detail "远端发布新 digest 后会自动重试；也可手动运行 bash deploy.sh update"
        return 0
    fi

    local local_digest
    local_digest="$(get_local_image_digest || true)"
    if [[ -n "${local_digest}" && "${local_digest}" == "${remote_digest}" ]]; then
        info "当前镜像已是最新，跳过更新"
        detail "digest: ${local_digest}"
        return 0
    fi

    if [[ -z "${local_digest}" ]]; then
        warn "本地尚未找到镜像，将拉取最新镜像"
    else
        warn "发现新镜像，开始更新"
        detail "本地: ${local_digest}"
        detail "远端: ${remote_digest}"
    fi

    if transactional_update; then
        rm -f "${FAILED_UPDATE_FILE}"
    else
        mkdir -p "$(dirname "${FAILED_UPDATE_FILE}")"
        printf '%s\n' "${remote_digest}" > "${FAILED_UPDATE_FILE}"
        warn "已记录失败 digest；自动更新将在远端 digest 变化后重试"
        return 1
    fi

    local updated_digest
    updated_digest="$(get_local_image_digest || true)"
    if [[ -n "${updated_digest}" ]]; then
        detail "当前 digest: ${updated_digest}"
    fi
}

current_crontab_without_auto_update() {
    crontab -l 2>/dev/null | awk \
        -v begin="${AUTO_UPDATE_MARKER_BEGIN}" \
        -v end="${AUTO_UPDATE_MARKER_END}" '
            $0 == begin { skip = 1; next }
            $0 == end { skip = 0; next }
            !skip { print }
        ' || true
}

current_auto_update_cron_line() {
    crontab -l 2>/dev/null | awk \
        -v begin="${AUTO_UPDATE_MARKER_BEGIN}" \
        -v end="${AUTO_UPDATE_MARKER_END}" '
            $0 == begin { show = 1; next }
            $0 == end { show = 0; next }
            show { print }
        ' | head -1 || true
}

resolve_auto_update_schedule() {
    case "${1:-}" in
        ""|daily) echo "20 4 * * *" ;;
        12h) echo "20 4,16 * * *" ;;
        6h) echo "20 */6 * * *" ;;
        hourly) echo "20 * * * *" ;;
        weekly) echo "20 4 * * 1" ;;
        *) echo "$1" ;;
    esac
}

cron_running() {
    pgrep -x cron &>/dev/null || pgrep -x crond &>/dev/null
}

cmd_enable_auto_update() {
    local schedule_arg="${1:-daily}"
    local schedule
    schedule="$(resolve_auto_update_schedule "${schedule_arg}")"

    if ! command -v crontab &>/dev/null; then
        error "未检测到 crontab"
        detail "请先安装 cron/cronie 后重试"
        return 1
    fi

    if ! [[ "${schedule}" =~ ^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+$ ]]; then
        error "cron 表达式格式不正确"
        detail "示例: bash deploy.sh enable-auto-update daily"
        detail "示例: bash deploy.sh enable-auto-update \"20 4 * * *\""
        return 1
    fi

    require_config_file
    mkdir -p "$(dirname "${AUTO_UPDATE_LOG}")"

    local quoted_script_dir quoted_log cron_line cron_path
    quoted_script_dir="$(shell_quote "${SCRIPT_DIR}")"
    quoted_log="$(shell_quote "${AUTO_UPDATE_LOG}")"
    cron_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    cron_line="${schedule} cd ${quoted_script_dir} && PATH=${cron_path}:\$PATH CPA_UPDATE_TRIGGER=cron bash deploy.sh auto-update >> ${quoted_log} 2>&1"

    local existing
    existing="$(current_crontab_without_auto_update)"

    {
        [[ -n "${existing}" ]] && printf '%s\n' "${existing}"
        printf '%s\n' "${AUTO_UPDATE_MARKER_BEGIN}"
        printf '%s\n' "${cron_line}"
        printf '%s\n' "${AUTO_UPDATE_MARKER_END}"
    } | crontab -

    info "已启用自动更新"
    detail "计划: ${schedule_arg} (${schedule})"
    detail "日志: ${AUTO_UPDATE_LOG}"
    detail "命令: bash deploy.sh auto-update"
    if ! cron_running; then
        warn "cron 服务似乎未运行，定时任务不会触发"
        detail "请确认 cron/crond 服务已经启动"
    fi
}

cmd_disable_auto_update() {
    if ! command -v crontab &>/dev/null; then
        error "未检测到 crontab"
        return 1
    fi

    if [[ -z "$(current_auto_update_cron_line)" ]]; then
        warn "当前未启用自动更新"
        return 0
    fi

    local existing
    existing="$(current_crontab_without_auto_update)"

    if [[ -n "${existing}" ]]; then
        printf '%s\n' "${existing}" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi

    info "已禁用自动更新"
}

cmd_auto_update_status() {
    if ! command -v crontab &>/dev/null; then
        error "未检测到 crontab"
        return 1
    fi

    step "自动更新状态"
    local entry
    entry="$(current_auto_update_cron_line)"
    if [[ -n "${entry}" ]]; then
        info "状态: 已启用"
        detail "计划: $(awk '{print $1, $2, $3, $4, $5}' <<<"${entry}")"
        detail "命令: ${entry}"
        if [[ "${entry}" != *"CPA_UPDATE_TRIGGER=cron"* ]]; then
            warn "当前任务是旧格式，日志无法区分自动与手动执行"
            detail "修复: bash deploy.sh enable-auto-update \"$(awk '{print $1, $2, $3, $4, $5}' <<<"${entry}")\""
        fi
        detail "服务器时区: $(date '+%Z (%z)')"
        detail "当前服务器时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        detail "当前北京时间: $(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %Z')"
        cron_running || warn "cron 服务似乎未运行，定时任务不会触发"

        if command -v journalctl &>/dev/null; then
            local latest_cron_record
            latest_cron_record="$(journalctl -u cron --since '7 days ago' --no-pager 2>/dev/null | grep -F 'deploy.sh auto-update' | tail -1 || true)"
            if [[ -n "${latest_cron_record}" ]]; then
                detail "最近 cron 触发: ${latest_cron_record}"
            else
                warn "最近 cron 触发: 过去 7 天未找到系统记录"
            fi
        else
            warn "最近 cron 触发: 系统没有 journalctl，无法自动查询"
        fi
    else
        warn "状态: 未启用"
        detail "开启: bash deploy.sh enable-auto-update"
    fi

    detail "日志: ${AUTO_UPDATE_LOG}"
    if [[ -s "${AUTO_UPDATE_LOG}" ]]; then
        echo ""
        detail "最近日志:"
        tail -n 8 "${AUTO_UPDATE_LOG}" | sed 's/^/       /'
    fi
}

cmd_uninstall() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }

    echo ""
    warn "即将完全卸载 CLI Proxy Manager"
    echo ""

    if ! confirm "确认卸载？(这将删除容器、凭证卷和配置文件)" "n"; then
        info "取消卸载"
        return 0
    fi

    cd "${SCRIPT_DIR}"
    # 先仅删除容器/网络；数据卷必须经过后续独立确认。
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" down 2>/dev/null || { error "停止现有栈失败"; return 1; }
    if confirm "是否删除 OAuth 凭证卷 (${AUTH_VOLUME})？" "n"; then
        if docker volume inspect "${AUTH_VOLUME}" >/dev/null 2>&1; then
            docker volume rm "${AUTH_VOLUME}" >/dev/null || { error "OAuth 凭证卷删除失败"; return 1; }
            docker volume inspect "${AUTH_VOLUME}" >/dev/null 2>&1 && { error "OAuth 凭证卷仍然存在"; return 1; }
        fi
    else
        warn "OAuth 凭证卷已保留；这不是无残留卸载"
    fi

    if confirm "是否删除配置文件 (config.yaml)？" "n"; then
        if [[ -d "${CONFIG_FILE}" ]]; then
            if find "${CONFIG_FILE}" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
                warn "config.yaml 是非空目录，未自动删除"
                detail "路径: ${CONFIG_FILE}"
            else
                rmdir "${CONFIG_FILE}"
                info "配置目录已删除"
            fi
        else
            rm -f "${CONFIG_FILE}"
            info "配置文件已删除"
        fi
    fi

    info "卸载完成"
}

# ========================== setup-claude ======================================

cmd_setup_claude() {
    local port="${CPA_PORT:-8317}"
    local api_key="${CPA_API_KEY}"

    if [[ -z "$api_key" && -f "$CONFIG_FILE" ]]; then
        api_key=$(awk -F'"' '/^[[:space:]]*-[[:space:]]*"/{print $2; exit}' "$CONFIG_FILE")
    fi

    if [[ -z "$api_key" ]]; then
        error "未找到 API Key。请先运行部署或设置 CPA_API_KEY"
        error "API Key not found. Run deploy first or set CPA_API_KEY"
        exit 1
    fi

    local settings_dir="${HOME}/.claude"
    local settings_file="${settings_dir}/settings.json"
    local base_url="http://127.0.0.1:${port}"

    mkdir -p "$settings_dir"

    local merged
    if command -v python3 &>/dev/null; then
        merged=$(python3 - "$settings_file" "$base_url" "$api_key" <<'PYEOF'
import json, sys, os
path, base_url, api_key = sys.argv[1], sys.argv[2], sys.argv[3]
settings = {}
if os.path.isfile(path):
    with open(path) as f:
        settings = json.load(f)
env = settings.setdefault("env", {})
env["ANTHROPIC_BASE_URL"] = base_url
env["ANTHROPIC_AUTH_TOKEN"] = api_key
mkts = settings.setdefault("extraKnownMarketplaces", {})
mkts["ecc"] = {"source": {"source": "github", "repo": "affaan-m/everything-claude-code"}}
print(json.dumps(settings, indent=2, ensure_ascii=False))
PYEOF
        )
    elif command -v node &>/dev/null; then
        merged=$(node -e "
const fs=require('fs'),p=process.argv[1],u=process.argv[2],k=process.argv[3];
let s={};try{s=JSON.parse(fs.readFileSync(p,'utf8'))}catch{}
s.env=s.env||{};s.env.ANTHROPIC_BASE_URL=u;s.env.ANTHROPIC_AUTH_TOKEN=k;
s.extraKnownMarketplaces=s.extraKnownMarketplaces||{};
s.extraKnownMarketplaces.ecc={source:{source:'github',repo:'affaan-m/everything-claude-code'}};
console.log(JSON.stringify(s,null,2));
" "$settings_file" "$base_url" "$api_key")
    else
        error "需要 python3 或 node 来操作 JSON 配置"
        error "python3 or node is required for JSON manipulation"
        exit 1
    fi

    echo "$merged" > "$settings_file"

    echo ""
    info "Claude Code 已配置 / Claude Code configured"
    echo ""
    echo -e "  ${BOLD}${settings_file}${NC} 已更新:"
    echo ""
    echo -e "  ANTHROPIC_BASE_URL   ${GREEN}${base_url}${NC}"
    echo -e "  ANTHROPIC_AUTH_TOKEN  ${GREEN}${api_key}${NC}"
    echo -e "  ECC 插件市场          ${GREEN}已启用 / enabled${NC}"
    echo ""
    echo -e "  ${DIM}现在可以直接运行 claude 命令使用代理${NC}"
    echo -e "  ${DIM}You can now run 'claude' directly with the proxy${NC}"
    echo ""
}

# ========================== Sub2API companion stack ===========================

require_sub2api_compose() {
    if ! command -v docker &>/dev/null; then
        error "未检测到 Docker"
        return 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        error "Docker 守护进程未运行"
        return 1
    fi
    if ! docker compose version &>/dev/null 2>&1; then
        error "Sub2API 功能要求 Docker Compose v2"
        return 1
    fi
    assert_regular_file "${SUB2API_COMPOSE_FILE}" || return 1
}

sub2api_compose() {
    local postgres_mode redis_mode
    postgres_mode="$(sub2api_env_value SUB2API_POSTGRES_MODE)"
    redis_mode="$(sub2api_env_value SUB2API_REDIS_MODE)"
    local -a profiles=()
    [[ "${postgres_mode:-managed}" == "managed" ]] && profiles+=(--profile managed-postgres)
    [[ "${redis_mode:-managed}" == "managed" ]] && profiles+=(--profile managed-redis)
    docker compose -p "${SUB2API_PROJECT_NAME}" \
        --env-file "${SUB2API_ENV_FILE}" \
        -f "${SUB2API_COMPOSE_FILE}" "${profiles[@]}" "$@"
}

sub2api_compose_all() {
    docker compose -p "${SUB2API_PROJECT_NAME}" \
        --env-file "${SUB2API_ENV_FILE}" \
        -f "${SUB2API_COMPOSE_FILE}" \
        --profile managed-postgres --profile managed-redis "$@"
}

generate_hex_secret() {
    local bytes="${1:-32}" secret=""
    if command -v openssl &>/dev/null; then
        secret="$(openssl rand -hex "${bytes}")"
    elif command -v od &>/dev/null && [[ -r /dev/urandom ]]; then
        secret="$(LC_ALL=C od -An -N "${bytes}" -tx1 /dev/urandom | tr -d ' \n')"
    fi
    if [[ "${#secret}" -ne $((bytes * 2)) || ! "${secret}" =~ ^[a-f0-9]+$ ]]; then
        error "无法生成安全随机密钥；请安装 openssl"
        return 1
    fi
    printf '%s' "${secret}"
}

sub2api_env_value() {
    local key="$1"
    awk -F= -v wanted="${key}" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            sub(/\r$/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' "${SUB2API_ENV_FILE}"
}

sub2api_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])${port}$"; then
        return 0
    fi
    if command -v lsof &>/dev/null && lsof -nP -iTCP:"${port}" -sTCP:LISTEN &>/dev/null; then
        return 0
    fi
    docker ps --format '{{.Ports}}' 2>/dev/null | grep -Eq "(^|[.:])${port}->" && return 0
    return 1
}

choose_sub2api_port() {
    local port
    for port in 8321 18321 28321 38321 48321; do
        if ! sub2api_port_in_use "${port}"; then
            printf '%s' "${port}"
            return 0
        fi
    done
    error "无法找到可用的 Sub2API 宿主端口"
    return 1
}

create_sub2api_env() {
    SUB2API_ENV_CREATED=false
    SUB2API_NEW_ADMIN_PASSWORD=""

    if [[ -e "${SUB2API_ENV_FILE}" ]]; then
        assert_regular_file "${SUB2API_ENV_FILE}" || return 1
        chmod 600 "${SUB2API_ENV_FILE}" 2>/dev/null || true
        return 0
    fi

    assert_safe_path "${SUB2API_ENV_FILE}" true || return 1
    assert_regular_file "${SUB2API_ENV_EXAMPLE_FILE}" || return 1

    local postgres_password redis_password admin_password jwt_secret totp_key temp_file host_port
    postgres_password="$(generate_hex_secret 24)" || return 1
    redis_password="$(generate_hex_secret 24)" || return 1
    admin_password="$(generate_hex_secret 18)" || return 1
    jwt_secret="$(generate_hex_secret 32)" || return 1
    totp_key="$(generate_hex_secret 32)" || return 1
    host_port="$(choose_sub2api_port)" || return 1
    temp_file="$(umask 077; mktemp "${SCRIPT_DIR}/sub2api.env.tmp.XXXXXX")" || {
        error "无法创建 Sub2API 临时配置文件"
        return 1
    }
    assert_safe_path "${temp_file}" true || return 1

    (
        umask 077
        cat > "${temp_file}" <<EOF
# Generated by CLI Proxy Manager. Keep this file private.
SUB2API_BIND_HOST=127.0.0.1
SUB2API_PORT=${host_port}
SUB2API_IMAGE=weishaw/sub2api:latest
SUB2API_POSTGRES_IMAGE=postgres:18-alpine
SUB2API_REDIS_IMAGE=redis:8-alpine
SUB2API_SERVER_MODE=release
SUB2API_RUN_MODE=standard
SUB2API_TZ=Asia/Shanghai
# Set each dependency to managed or external independently.
SUB2API_POSTGRES_MODE=managed
SUB2API_DATABASE_HOST=postgres
SUB2API_DATABASE_PORT=5432
SUB2API_POSTGRES_USER=sub2api
SUB2API_POSTGRES_PASSWORD=${postgres_password}
SUB2API_POSTGRES_DB=sub2api
SUB2API_DATABASE_SSLMODE=disable
SUB2API_REDIS_MODE=managed
SUB2API_REDIS_HOST=redis
SUB2API_REDIS_PORT=6379
SUB2API_REDIS_PASSWORD=${redis_password}
SUB2API_REDIS_DB=0
SUB2API_ADMIN_EMAIL=admin@sub2api.local
SUB2API_ADMIN_PASSWORD=${admin_password}
SUB2API_JWT_SECRET=${jwt_secret}
SUB2API_TOTP_ENCRYPTION_KEY=${totp_key}
SUB2API_URL_ALLOWLIST_ENABLED=false
SUB2API_ALLOW_INSECURE_HTTP=true
SUB2API_ALLOW_PRIVATE_HOSTS=true
EOF
        chmod 600 "${temp_file}" 2>/dev/null || true
    ) || { rm -f "${temp_file}"; return 1; }

    if [[ -e "${SUB2API_ENV_FILE}" ]]; then
        rm -f "${temp_file}"
        error "sub2api.env 已被其他进程创建，请重试"
        return 1
    fi
    mv "${temp_file}" "${SUB2API_ENV_FILE}"
    SUB2API_ENV_CREATED=true
    SUB2API_NEW_ADMIN_PASSWORD="${admin_password}"
}

validate_sub2api_env() {
    assert_regular_file "${SUB2API_ENV_FILE}" || return 1
    local key value bind_host port postgres_mode redis_mode database_host redis_host dependency_port
    for key in SUB2API_POSTGRES_PASSWORD SUB2API_ADMIN_PASSWORD SUB2API_JWT_SECRET SUB2API_TOTP_ENCRYPTION_KEY; do
        value="$(sub2api_env_value "${key}")"
        [[ -n "${value}" ]] || { error "sub2api.env 缺少 ${key}"; return 1; }
    done

    postgres_mode="$(sub2api_env_value SUB2API_POSTGRES_MODE)"
    redis_mode="$(sub2api_env_value SUB2API_REDIS_MODE)"
    postgres_mode="${postgres_mode:-managed}"
    redis_mode="${redis_mode:-managed}"
    [[ "${postgres_mode}" == "managed" || "${postgres_mode}" == "external" ]] || {
        error "SUB2API_POSTGRES_MODE 只能是 managed 或 external"
        return 1
    }
    [[ "${redis_mode}" == "managed" || "${redis_mode}" == "external" ]] || {
        error "SUB2API_REDIS_MODE 只能是 managed 或 external"
        return 1
    }

    database_host="$(sub2api_env_value SUB2API_DATABASE_HOST)"
    redis_host="$(sub2api_env_value SUB2API_REDIS_HOST)"
    if [[ "${postgres_mode}" == "external" && -z "${database_host}" ]]; then
        error "external PostgreSQL 模式要求 SUB2API_DATABASE_HOST"
        return 1
    fi
    if [[ "${redis_mode}" == "external" && -z "${redis_host}" ]]; then
        error "external Redis 模式要求 SUB2API_REDIS_HOST"
        return 1
    fi
    database_host="${database_host:-postgres}"
    redis_host="${redis_host:-redis}"
    if [[ "${postgres_mode}" == "managed" && "${database_host}" != "postgres" ]]; then
        error "managed PostgreSQL 模式要求 SUB2API_DATABASE_HOST=postgres"
        return 1
    fi
    if [[ "${redis_mode}" == "managed" && "${redis_host}" != "redis" ]]; then
        error "managed Redis 模式要求 SUB2API_REDIS_HOST=redis"
        return 1
    fi
    if [[ "${postgres_mode}" == "external" && ( "${database_host}" == "127.0.0.1" || "${database_host}" == "localhost" ) ]]; then
        error "外部 PostgreSQL 在宿主机时请使用 host.docker.internal，不能使用 localhost"
        return 1
    fi
    if [[ "${redis_mode}" == "external" && ( "${redis_host}" == "127.0.0.1" || "${redis_host}" == "localhost" ) ]]; then
        error "外部 Redis 在宿主机时请使用 host.docker.internal，不能使用 localhost"
        return 1
    fi
    if [[ "${redis_mode}" == "managed" && -z "$(sub2api_env_value SUB2API_REDIS_PASSWORD)" ]]; then
        error "managed Redis 模式要求 SUB2API_REDIS_PASSWORD"
        return 1
    fi

    for key in SUB2API_DATABASE_PORT SUB2API_REDIS_PORT; do
        dependency_port="$(sub2api_env_value "${key}")"
        [[ -z "${dependency_port}" ]] && continue
        [[ "${dependency_port}" =~ ^[0-9]+$ ]] && (( dependency_port >= 1 && dependency_port <= 65535 )) || {
            error "${key} 必须是 1..65535 的整数"
            return 1
        }
    done

    bind_host="$(sub2api_env_value SUB2API_BIND_HOST)"
    case "${bind_host:-127.0.0.1}" in
        127.0.0.1|0.0.0.0) ;;
        *) error "SUB2API_BIND_HOST 仅支持 127.0.0.1 或 0.0.0.0"; return 1 ;;
    esac

    port="$(sub2api_env_value SUB2API_PORT)"
    port="${port:-8321}"
    [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || {
        error "SUB2API_PORT 必须是 1..65535 的整数"
        return 1
    }
}

wait_for_sub2api_container() {
    local container_name="$1" label="$2" status="" count
    echo -en "     等待 ${label} 就绪 "
    for count in $(seq 1 60); do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container_name}" 2>/dev/null || true)"
        if [[ "${status}" == "healthy" ]]; then
            echo ""
            return 0
        fi
        if [[ "${status}" == "exited" || "${status}" == "dead" ]]; then
            echo ""
            return 1
        fi
        echo -n "·"
        sleep 2
    done
    echo ""
    return 1
}

start_sub2api_stack() {
    local recreate="${1:-false}" postgres_mode redis_mode
    local -a managed_services=() app_args=(up -d)
    postgres_mode="$(sub2api_env_value SUB2API_POSTGRES_MODE)"
    redis_mode="$(sub2api_env_value SUB2API_REDIS_MODE)"
    postgres_mode="${postgres_mode:-managed}"
    redis_mode="${redis_mode:-managed}"

    if [[ "${postgres_mode}" == "managed" ]]; then
        managed_services+=(postgres)
    else
        sub2api_compose_all stop postgres >/dev/null 2>&1 || true
    fi
    if [[ "${redis_mode}" == "managed" ]]; then
        managed_services+=(redis)
    else
        sub2api_compose_all stop redis >/dev/null 2>&1 || true
    fi

    if (( ${#managed_services[@]} > 0 )); then
        sub2api_compose up -d "${managed_services[@]}"
    fi
    if [[ "${postgres_mode}" == "managed" ]]; then
        wait_for_sub2api_container "${SUB2API_POSTGRES_CONTAINER_NAME}" "PostgreSQL" || return 1
    fi
    if [[ "${redis_mode}" == "managed" ]]; then
        wait_for_sub2api_container "${SUB2API_REDIS_CONTAINER_NAME}" "Redis" || return 1
    fi

    [[ "${recreate}" == "true" ]] && app_args+=(--force-recreate)
    app_args+=(sub2api)
    sub2api_compose "${app_args[@]}"
    wait_for_sub2api_container "${SUB2API_CONTAINER_NAME}" "Sub2API"
}

show_sub2api_result() {
    local bind_host port admin_email display_host postgres_mode redis_mode
    bind_host="$(sub2api_env_value SUB2API_BIND_HOST)"
    port="$(sub2api_env_value SUB2API_PORT)"
    admin_email="$(sub2api_env_value SUB2API_ADMIN_EMAIL)"
    display_host="${bind_host:-127.0.0.1}"
    [[ "${display_host}" == "0.0.0.0" ]] && display_host="127.0.0.1"
    postgres_mode="$(sub2api_env_value SUB2API_POSTGRES_MODE)"
    redis_mode="$(sub2api_env_value SUB2API_REDIS_MODE)"

    echo ""
    detail "访问地址: http://${display_host}:${port:-8321}"
    detail "管理员邮箱: ${admin_email:-admin@sub2api.local}"
    detail "PostgreSQL 模式: ${postgres_mode:-managed}"
    detail "Redis 模式: ${redis_mode:-managed}"
    detail "配置文件: ${SUB2API_ENV_FILE}"
    if [[ "${SUB2API_ENV_CREATED}" == "true" ]]; then
        detail "首次管理员密码: ${SUB2API_NEW_ADMIN_PASSWORD}"
        warn "请立即保存密码，并保护 sub2api.env"
    fi
}

prepare_sub2api() {
    require_sub2api_compose || return 1
    create_sub2api_env || return 1
    validate_sub2api_env || return 1
    sub2api_compose config --quiet || { error "Sub2API Compose 配置校验失败"; return 1; }
}

cmd_sub2api_init() {
    step "生成 Sub2API 配置"
    assert_regular_file "${SUB2API_COMPOSE_FILE}" || return 1
    create_sub2api_env || return 1
    validate_sub2api_env || return 1
    info "Sub2API 配置已准备"
    detail "配置文件: ${SUB2API_ENV_FILE}"
    detail "默认模式: managed PostgreSQL + managed Redis"
    warn "如需混合部署，请先编辑两个 MODE 和对应的 HOST/PORT，再运行 deploy"
    if [[ "${SUB2API_ENV_CREATED}" == "true" ]]; then
        detail "首次管理员密码: ${SUB2API_NEW_ADMIN_PASSWORD}"
        warn "请立即保存密码，并保护 sub2api.env"
    fi
}

cmd_sub2api_deploy() {
    step "一键部署 Sub2API"
    prepare_sub2api || return 1
    sub2api_compose pull
    if start_sub2api_stack; then
        info "Sub2API 已启动"
        show_sub2api_result
    else
        error "Sub2API 未通过健康检查"
        sub2api_compose logs --tail 80 sub2api || true
        return 1
    fi
}

cmd_sub2api_start() {
    step "启动 Sub2API"
    prepare_sub2api || return 1
    start_sub2api_stack || { error "Sub2API 或托管依赖未通过健康检查"; return 1; }
    info "Sub2API 已启动"
    show_sub2api_result
}

cmd_sub2api_stop() {
    require_sub2api_compose || return 1
    assert_regular_file "${SUB2API_ENV_FILE}" || return 1
    step "停止 Sub2API"
    sub2api_compose_all stop
    info "Sub2API 已停止，数据卷已保留"
}

cmd_sub2api_restart() {
    step "重建并重启 Sub2API"
    prepare_sub2api || return 1
    start_sub2api_stack true || { error "Sub2API 或托管依赖未通过健康检查"; return 1; }
    info "Sub2API 已重新启动"
    show_sub2api_result
}

cmd_sub2api_status() {
    require_sub2api_compose || return 1
    assert_regular_file "${SUB2API_ENV_FILE}" || return 1
    step "Sub2API 状态"
    sub2api_compose_all ps
    local health
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${SUB2API_CONTAINER_NAME}" 2>/dev/null || true)"
    detail "应用健康状态: ${health:-not-created}"
    show_sub2api_result
}

cmd_sub2api_logs() {
    local service="${1:-sub2api}"
    require_sub2api_compose || return 1
    assert_regular_file "${SUB2API_ENV_FILE}" || return 1
    sub2api_compose_all logs -f --tail 200 "${service}"
}

cmd_sub2api_update() {
    step "更新 Sub2API 栈"
    prepare_sub2api || return 1
    sub2api_compose pull
    start_sub2api_stack || { error "更新后健康检查失败"; sub2api_compose logs --tail 80 sub2api || true; return 1; }
    info "Sub2API 已更新并通过健康检查"
}

cmd_sub2api_doctor() {
    step "检查 Sub2API 部署"
    require_sub2api_compose || return 1
    assert_regular_file "${SUB2API_ENV_FILE}" || return 1
    validate_sub2api_env || return 1
    sub2api_compose config --quiet || { error "Sub2API Compose 配置校验失败"; return 1; }
    info "Compose 配置有效"
    local bind_host
    bind_host="$(sub2api_env_value SUB2API_BIND_HOST)"
    if [[ "${bind_host}" == "0.0.0.0" ]]; then
        warn "Sub2API 当前对所有网络接口开放"
        detail "请使用防火墙和 HTTPS 反向代理"
    else
        info "Sub2API 仅绑定本机"
    fi
    cmd_sub2api_status
}

cmd_sub2api_uninstall() {
    require_sub2api_compose || return 1
    assert_regular_file "${SUB2API_ENV_FILE}" || return 1
    echo ""
    warn "即将卸载 Sub2API 容器"
    if ! confirm "确认停止并删除 Sub2API 容器和网络？" "n"; then
        info "取消卸载"
        return 0
    fi

    local delete_volumes=false
    if confirm "是否永久删除 Sub2API、PostgreSQL 和 Redis 数据卷？" "n"; then
        delete_volumes=true
    fi

    if $delete_volumes; then
        sub2api_compose_all down -v
        info "Sub2API 容器、网络和数据卷已删除"
    else
        sub2api_compose_all down
        info "Sub2API 容器和网络已删除，数据卷仍保留"
    fi

    if ! $delete_volumes; then
        warn "数据卷已保留"
    fi

    if confirm "是否删除包含密钥的 sub2api.env？" "n"; then
        assert_regular_file "${SUB2API_ENV_FILE}" || return 1
        rm -f "${SUB2API_ENV_FILE}"
        info "sub2api.env 已删除"
    fi
}

show_sub2api_help() {
    echo ""
    echo -e "  ${BOLD}Sub2API companion stack${NC}"
    echo -e "  bash deploy.sh sub2api ${DIM}[action]${NC}"
    echo ""
    echo -e "    ${CYAN}deploy${NC}     生成密钥并一键部署（默认）"
    echo -e "    ${CYAN}init${NC}       只生成配置，便于先选择依赖模式"
    echo -e "    ${CYAN}start${NC}      启动或创建容器"
    echo -e "    ${CYAN}stop${NC}       停止容器并保留数据"
    echo -e "    ${CYAN}restart${NC}    重建并重启容器"
    echo -e "    ${CYAN}status${NC}     查看容器和健康状态"
    echo -e "    ${CYAN}logs [服务]${NC} 查看日志（默认 sub2api）"
    echo -e "    ${CYAN}update${NC}     拉取最新镜像并重建"
    echo -e "    ${CYAN}doctor${NC}     检查配置和暴露范围"
    echo -e "    ${CYAN}uninstall${NC}  卸载；数据和密钥分别确认"
    echo ""
    echo -e "  ${DIM}依赖模式在 sub2api.env 中分别设置:${NC}"
    echo -e "    SUB2API_POSTGRES_MODE=managed|external"
    echo -e "    SUB2API_REDIS_MODE=managed|external"
    echo ""
}

cmd_sub2api() {
    local action="${1:-deploy}"
    [[ $# -gt 0 ]] && shift || true
    case "${action}" in
        deploy|install) cmd_sub2api_deploy ;;
        init|configure) cmd_sub2api_init ;;
        start) cmd_sub2api_start ;;
        stop) cmd_sub2api_stop ;;
        restart) cmd_sub2api_restart ;;
        status) cmd_sub2api_status ;;
        logs) cmd_sub2api_logs "${1:-sub2api}" ;;
        update) cmd_sub2api_update ;;
        doctor) cmd_sub2api_doctor ;;
        uninstall) cmd_sub2api_uninstall ;;
        help|--help|-h) show_sub2api_help ;;
        *) error "未知 Sub2API 操作: ${action}"; show_sub2api_help; return 1 ;;
    esac
}

# ========================== Cursor Bridge sidecar ============================

require_cursor_bridge_compose() {
    if ! command -v docker &>/dev/null; then
        error "未检测到 Docker"
        return 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        error "Docker 守护进程未运行"
        return 1
    fi
    if ! docker compose version &>/dev/null 2>&1; then
        error "Cursor Bridge 要求 Docker Compose v2"
        return 1
    fi
    assert_regular_file "${CURSOR_BRIDGE_COMPOSE_FILE}" || return 1
}

cursor_bridge_compose() {
    docker compose -p "${CURSOR_BRIDGE_PROJECT_NAME}" \
        -f "${CURSOR_BRIDGE_COMPOSE_FILE}" "$@"
}

cursor_bridge_env_value() {
    local key="$1"
    [[ -f "${CURSOR_BRIDGE_ENV_FILE}" ]] || return 0
    awk -F= -v wanted="${key}" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            sub(/\r$/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' "${CURSOR_BRIDGE_ENV_FILE}"
}

validate_cursor_bridge_env() {
    assert_regular_file "${CURSOR_BRIDGE_ENV_FILE}" || return 1
    local cursor_key bridge_key
    cursor_key="$(cursor_bridge_env_value CURSOR_API_KEY)"
    bridge_key="$(cursor_bridge_env_value CURSOR_BRIDGE_API_KEY)"
    [[ -n "${cursor_key}" && "${cursor_key}" != replace-locally-* ]] || {
        error "运行 bash deploy.sh cursor-bridge，按提示粘贴 Cursor API key"
        return 1
    }
    [[ "${bridge_key}" =~ ^[A-Fa-f0-9]{64}$ ]] || {
        error "CURSOR_BRIDGE_API_KEY 必须是 64 位 hex，请重跑 bash deploy.sh cursor-bridge init"
        return 1
    }
    [[ "${cursor_key}" != "${bridge_key}" ]] || {
        error "两把 Cursor Bridge key 必须不同"
        return 1
    }
    if [[ -n "${CPA_API_KEY}" && ( "${cursor_key}" == "${CPA_API_KEY}" || "${bridge_key}" == "${CPA_API_KEY}" ) ]]; then
        error "禁止复用 CPA_API_KEY"
        return 1
    fi
    if [[ -n "${CPA_MANAGEMENT_KEY}" && ( "${cursor_key}" == "${CPA_MANAGEMENT_KEY}" || "${bridge_key}" == "${CPA_MANAGEMENT_KEY}" ) ]]; then
        error "禁止复用 CPA_MANAGEMENT_KEY"
        return 1
    fi
    if grep -Eq '^[[:space:]]*(CURSOR_CONFIG_DIRS|CURSOR_ACCOUNT_DIRS)=' "${CURSOR_BRIDGE_ENV_FILE}"; then
        error "cursor-bridge.env 不能设 CURSOR_CONFIG_DIRS / CURSOR_ACCOUNT_DIRS"
        return 1
    fi
    chmod 600 "${CURSOR_BRIDGE_ENV_FILE}" 2>/dev/null || true
}

set_cursor_bridge_env_key() {
    local name="$1" value_file="$2" tmp
    tmp="$(umask 077; mktemp "${SCRIPT_DIR}/cursor-bridge.env.tmp.XXXXXX")" || return 1
    awk -v k="${name}" -v vf="${value_file}" '
        BEGIN { getline v < vf; close(vf) }
        index($0, k "=") == 1 { print k "=" v; found=1; next }
        { print }
        END { if (!found) print k "=" v }
    ' "${CURSOR_BRIDGE_ENV_FILE}" > "${tmp}"
    mv "${tmp}" "${CURSOR_BRIDGE_ENV_FILE}"
    chmod 600 "${CURSOR_BRIDGE_ENV_FILE}" 2>/dev/null || true
}

prompt_cursor_api_key() {
    local current force="${1:-}" key value_file
    current="$(cursor_bridge_env_value CURSOR_API_KEY)"
    if [[ -z "${force}" && -n "${current}" && "${current}" != replace-locally-* ]]; then
        if ! confirm "已保存一把 Cursor key，要更换吗？" "n"; then
            return 0
        fi
    fi
    if [[ ! -t 0 ]]; then
        error "需要交互输入 Cursor API key。在终端运行 bash deploy.sh cursor-bridge"
        return 1
    fi
    echo ""
    echo -e "  ${DIM}从 https://cursor.com/dashboard/api 创建 key，弹窗里复制完整值。输入时不显示。${NC}"
    echo -en "  ${MAGENTA}?${NC}  粘贴 Cursor API key: "
    IFS= read -rs key
    echo ""
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ -n "${key}" ]] || { error "key 不能为空"; return 1; }
    [[ "${key}" != replace-locally-* ]] || { error "请粘贴真实的 Cursor key"; return 1; }
    value_file="$(umask 077; mktemp "${SCRIPT_DIR}/cursor-bridge.env.tmp.XXXXXX")" || return 1
    printf '%s' "${key}" > "${value_file}"
    set_cursor_bridge_env_key CURSOR_API_KEY "${value_file}"
    rm -f "${value_file}"
    info "已写入 CURSOR_API_KEY（不会打印）"
}

ensure_cursor_bridge_ready() {
    create_cursor_bridge_env || return 1
    local cursor_key bridge_key value_file
    bridge_key="$(cursor_bridge_env_value CURSOR_BRIDGE_API_KEY)"
    if [[ ! "${bridge_key}" =~ ^[A-Fa-f0-9]{64}$ ]]; then
        bridge_key="$(generate_hex_secret 32)" || return 1
        value_file="$(umask 077; mktemp "${SCRIPT_DIR}/cursor-bridge.env.tmp.XXXXXX")" || return 1
        printf '%s' "${bridge_key}" > "${value_file}"
        set_cursor_bridge_env_key CURSOR_BRIDGE_API_KEY "${value_file}"
        rm -f "${value_file}"
        info "已自动生成 CURSOR_BRIDGE_API_KEY"
    fi
    cursor_key="$(cursor_bridge_env_value CURSOR_API_KEY)"
    if [[ -z "${cursor_key}" || "${cursor_key}" == replace-locally-* ]]; then
        prompt_cursor_api_key force || return 1
    fi
    validate_cursor_bridge_env
}

create_cursor_bridge_env() {
    if [[ -e "${CURSOR_BRIDGE_ENV_FILE}" ]]; then
        assert_regular_file "${CURSOR_BRIDGE_ENV_FILE}" || return 1
        chmod 600 "${CURSOR_BRIDGE_ENV_FILE}" 2>/dev/null || true
        return 0
    fi
    assert_safe_path "${CURSOR_BRIDGE_ENV_FILE}" true || return 1
    assert_regular_file "${CURSOR_BRIDGE_ENV_EXAMPLE_FILE}" || return 1
    local bridge_key temp_file
    bridge_key="$(generate_hex_secret 32)" || return 1
    temp_file="$(umask 077; mktemp "${SCRIPT_DIR}/cursor-bridge.env.tmp.XXXXXX")" || {
        error "无法创建 cursor-bridge.env"
        return 1
    }
    sed "s/replace-locally-with-random-64-hex-key/${bridge_key}/" "${CURSOR_BRIDGE_ENV_EXAMPLE_FILE}" > "${temp_file}"
    chmod 600 "${temp_file}" 2>/dev/null || true
    if [[ -e "${CURSOR_BRIDGE_ENV_FILE}" ]]; then
        rm -f "${temp_file}"
        error "cursor-bridge.env 已被其他进程创建，请重试"
        return 1
    fi
    mv "${temp_file}" "${CURSOR_BRIDGE_ENV_FILE}"
}

ensure_cursor_bridge_image() {
    if docker image inspect "${CURSOR_BRIDGE_IMAGE}" >/dev/null 2>&1; then
        return 0
    fi
    step "构建钉死 Cursor Bridge 镜像"
    if command -v docker >/dev/null && docker buildx version >/dev/null 2>&1; then
        docker buildx build --load \
            --label "org.opencontainers.image.source=${CURSOR_BRIDGE_SOURCE_REPOSITORY}" \
            --label "org.opencontainers.image.revision=${CURSOR_BRIDGE_SOURCE_COMMIT}" \
            -t "${CURSOR_BRIDGE_IMAGE}" \
            "${CURSOR_BRIDGE_SOURCE_REPOSITORY}.git#${CURSOR_BRIDGE_SOURCE_COMMIT}"
    else
        docker build \
            --label "org.opencontainers.image.source=${CURSOR_BRIDGE_SOURCE_REPOSITORY}" \
            --label "org.opencontainers.image.revision=${CURSOR_BRIDGE_SOURCE_COMMIT}" \
            -t "${CURSOR_BRIDGE_IMAGE}" \
            "${CURSOR_BRIDGE_SOURCE_REPOSITORY}.git#${CURSOR_BRIDGE_SOURCE_COMMIT}"
    fi
}

cursor_bridge_connect_cpa() {
    if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        warn "${CONTAINER_NAME} 未运行，先 bash deploy.sh start，再挂 Cursor Bridge 网"
        return 1
    fi
    if docker inspect "${CONTAINER_NAME}" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -Fq "${CURSOR_BRIDGE_NETWORK}"; then
        return 0
    fi
    docker network connect "${CURSOR_BRIDGE_NETWORK}" "${CONTAINER_NAME}"
    info "已把 ${CONTAINER_NAME} 挂到 ${CURSOR_BRIDGE_NETWORK}"
}

cursor_bridge_ensure_openai_compatibility() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        warn "没有 config.yaml，跳过 openai-compatibility"
        return 0
    fi
    assert_regular_file "${CONFIG_FILE}" || return 1
    local bridge_key tmp backup
    if grep -Fq 'http://cursor-bridge-guard:8080/v1' "${CONFIG_FILE}"; then
        backup="${SCRIPT_DIR}/config.yaml.bak.cursor-bridge"
        if [[ ! -e "${backup}" ]]; then
            cp "${CONFIG_FILE}" "${backup}"
            chmod 600 "${backup}" 2>/dev/null || true
        fi
        tmp="$(umask 077; mktemp "${SCRIPT_DIR}/config.yaml.tmp.XXXXXX")" || return 1
        sed 's|http://cursor-bridge-guard:8080/v1|http://cursor-bridge:8765/v1|g' "${CONFIG_FILE}" > "${tmp}"
        mv "${tmp}" "${CONFIG_FILE}"
        chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
        info "已把 cursor-bridge 上游改成直连 :8765"
        return 2
    fi
    if grep -Eq '^[[:space:]]*-[[:space:]]*name:[[:space:]]*cursor-bridge[[:space:]]*$' "${CONFIG_FILE}"; then
        info "config.yaml 已有 cursor-bridge"
        return 0
    fi
    bridge_key="$(cursor_bridge_env_value CURSOR_BRIDGE_API_KEY)"
    [[ "${bridge_key}" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    backup="${SCRIPT_DIR}/config.yaml.bak.cursor-bridge"
    if [[ ! -e "${backup}" ]]; then
        cp "${CONFIG_FILE}" "${backup}"
        chmod 600 "${backup}" 2>/dev/null || true
    fi
    tmp="$(umask 077; mktemp "${SCRIPT_DIR}/config.yaml.tmp.XXXXXX")" || return 1
    {
        cat "${CONFIG_FILE}"
        if grep -Eq '^[[:space:]]*openai-compatibility:' "${CONFIG_FILE}"; then
            printf '\n  - name: cursor-bridge\n    prefix: cursor\n    base-url: http://cursor-bridge:8765/v1\n    api-key-entries:\n      - api-key: "%s"\n    models:\n      - name: auto\n        alias: cursor-auto\n' "${bridge_key}"
        else
            printf '\nopenai-compatibility:\n  - name: cursor-bridge\n    prefix: cursor\n    base-url: http://cursor-bridge:8765/v1\n    api-key-entries:\n      - api-key: "%s"\n    models:\n      - name: auto\n        alias: cursor-auto\n' "${bridge_key}"
        fi
    } > "${tmp}"
    mv "${tmp}" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
    info "已写入 config.yaml 的 cursor-bridge 上游"
    return 2
}

cursor_bridge_fetch_models_json() {
    local out_file="$1"
    docker inspect "${CURSOR_BRIDGE_CONTAINER_NAME}" >/dev/null 2>&1 || {
        error "cursor-bridge 未运行，先 bash deploy.sh cursor-bridge"
        return 1
    }
    docker exec "${CURSOR_BRIDGE_CONTAINER_NAME}" \
        sh -c 'curl -sS -H "Authorization: Bearer ${CURSOR_BRIDGE_API_KEY}" http://127.0.0.1:8765/v1/models' \
        > "${out_file}" || {
        error "无法从桥拉取 /v1/models"
        return 1
    }
}

cursor_bridge_write_models_from_json() {
    local json_file="$1" out_file="$2" only="${3:-}"
    if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
        error "sync-models 需要 python3"
        return 1
    fi
    local py
    py="$(command -v python3 || command -v python)"
    "${py}" - "${json_file}" "${CONFIG_FILE}" "${out_file}" "${only}" <<'PY'
import json, re, sys

json_path, config_path, out_path = sys.argv[1:4]
only = sys.argv[4].strip() if len(sys.argv) > 4 else ""
allow = {x.strip() for x in only.split(",") if x.strip()} if only else None
payload = json.load(open(json_path, encoding="utf-8"))
if not isinstance(payload, dict) or "data" not in payload:
    sys.stderr.write("桥返回的不是模型列表\n")
    sys.exit(1)
ids = []
seen = set()
for item in payload.get("data") or []:
    mid = item.get("id") if isinstance(item, dict) else None
    if not mid or not re.fullmatch(r"[A-Za-z0-9._:-]+", str(mid)):
        continue
    if allow is not None and mid not in allow:
        continue
    if mid in seen:
        continue
    seen.add(mid)
    ids.append(mid)
if "auto" not in seen:
    ids.insert(0, "auto")
elif ids and ids[0] != "auto":
    ids = ["auto"] + [i for i in ids if i != "auto"]

block = ["    models:\n"]
for mid in ids:
    alias = "cursor-auto" if mid == "auto" else mid
    block.append("      - name: %s\n" % mid)
    block.append("        alias: %s\n" % alias)
models_block = "".join(block)

src = open(config_path, encoding="utf-8").read().splitlines(True)
out = []
i = 0
found = False
while i < len(src):
    line = src[i]
    if re.match(r"^[ \t]*-[ \t]*name:[ \t]*cursor-bridge[ \t]*$", line):
        found = True
        out.append(line)
        i += 1
        inserted = False
        while i < len(src):
            nxt = src[i]
            if re.match(r"^[ \t]*models:[ \t]*$", nxt):
                i += 1
                while i < len(src) and (src[i].startswith("      ") or src[i].strip() == ""):
                    i += 1
                out.append(models_block)
                inserted = True
                break
            if re.match(r"^  - ", nxt) or re.match(r"^[A-Za-z]", nxt):
                out.append(models_block)
                inserted = True
                break
            out.append(nxt)
            i += 1
        if not inserted:
            out.append(models_block)
        continue
    out.append(line)
    i += 1
if not found:
    sys.stderr.write("config.yaml 里没有 cursor-bridge 段\n")
    sys.exit(1)
open(out_path, "w", encoding="utf-8").writelines(out)
print(len(ids))
PY
}

cmd_cursor_bridge_sync_models() {
    local only="${1:-}"
    require_cursor_bridge_compose || return 1
    validate_cursor_bridge_env || return 1
    assert_regular_file "${CONFIG_FILE}" || return 1
    grep -Eq '^[[:space:]]*-[[:space:]]*name:[[:space:]]*cursor-bridge[[:space:]]*$' "${CONFIG_FILE}" || {
        error "config.yaml 还没有 cursor-bridge。先 bash deploy.sh cursor-bridge"
        return 1
    }
    local json_file tmp count backup
    json_file="$(umask 077; mktemp "${SCRIPT_DIR}/cursor-bridge.models.json.XXXXXX")" || return 1
    tmp="$(umask 077; mktemp "${SCRIPT_DIR}/config.yaml.tmp.XXXXXX")" || { rm -f "${json_file}"; return 1; }
    if ! cursor_bridge_fetch_models_json "${json_file}"; then
        rm -f "${json_file}" "${tmp}"
        return 1
    fi
    count="$(cursor_bridge_write_models_from_json "${json_file}" "${tmp}" "${only}")" || {
        rm -f "${json_file}" "${tmp}"
        return 1
    }
    backup="${SCRIPT_DIR}/config.yaml.bak.cursor-bridge"
    if [[ ! -e "${backup}" ]]; then
        cp "${CONFIG_FILE}" "${backup}"
        chmod 600 "${backup}" 2>/dev/null || true
    fi
    mv "${tmp}" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
    rm -f "${json_file}"
    info "已把桥上 ${count} 个模型写入 config.yaml（auto 仍叫 cursor-auto）"
    info "正在重启 CPA，让面板读到新列表（约几秒）"
    cmd_restart || warn "CPA 重启失败，请稍后 bash deploy.sh restart"
}

maybe_start_cursor_bridge_sidecar() {
    [[ -f "${CURSOR_BRIDGE_ENV_FILE}" ]] || return 0
    if ! validate_cursor_bridge_env >/dev/null 2>&1; then
        detail "发现 cursor-bridge.env 但还缺 Cursor key。在终端执行: bash deploy.sh cursor-bridge"
        return 0
    fi
    info "检测到 cursor-bridge.env，同时启动 Cursor Bridge"
    cmd_cursor_bridge_start || warn "Cursor Bridge 启动失败，CPA 已在运行。可单独执行 bash deploy.sh cursor-bridge start"
}

cmd_cursor_bridge_init() {
    require_cursor_bridge_compose || return 1
    create_cursor_bridge_env || return 1
    prompt_cursor_api_key || return 1
    ensure_cursor_bridge_ready || return 1
    info "Cursor Bridge 已初始化。接下来: bash deploy.sh cursor-bridge start"
}

cmd_cursor_bridge_build() {
    require_cursor_bridge_compose || return 1
    validate_cursor_bridge_env || return 1
    if docker image inspect "${CURSOR_BRIDGE_IMAGE}" >/dev/null 2>&1; then
        docker rmi "${CURSOR_BRIDGE_IMAGE}" >/dev/null 2>&1 || true
    fi
    ensure_cursor_bridge_image
    info "已构建 ${CURSOR_BRIDGE_IMAGE}"
}

cmd_cursor_bridge_configure() {
    require_cursor_bridge_compose || return 1
    create_cursor_bridge_env || return 1
    prompt_cursor_api_key force || return 1
    ensure_cursor_bridge_ready || return 1
    if docker inspect "${CURSOR_BRIDGE_CONTAINER_NAME}" >/dev/null 2>&1; then
        ensure_cpa_cursor_bridge_network || return 1
        cursor_bridge_compose up -d --remove-orphans
        cursor_bridge_connect_cpa || true
        info "已更换 Cursor key 并重建桥容器"
    else
        info "已更换 Cursor key。接下来: bash deploy.sh cursor-bridge start"
    fi
}

cmd_cursor_bridge_start() {
    require_cursor_bridge_compose || return 1
    ensure_cursor_bridge_ready || return 1
    ensure_cursor_bridge_image || return 1
    cursor_bridge_compose config --quiet || { error "Cursor Bridge Compose 校验失败"; return 1; }
    ensure_cpa_cursor_bridge_network || return 1
    cursor_bridge_compose up -d --remove-orphans
    docker network rm cursor-bridge-backend >/dev/null 2>&1 || true
    cursor_bridge_connect_cpa || true
    local compat_status=0
    cursor_bridge_ensure_openai_compatibility || compat_status=$?
    if [[ "${compat_status}" -eq 2 ]]; then
        info "正在重启 CPA，让它读到 Cursor 上游（约几秒）"
        cmd_restart || warn "CPA 重启失败，请稍后执行 bash deploy.sh restart"
    elif [[ "${compat_status}" -ne 0 ]]; then
        warn "写入 openai-compatibility 失败。可检查 config.yaml 后执行 bash deploy.sh restart"
    fi
    info "Cursor Bridge 已启动。CPA 直连 :8765，无主机端口"
    info "CPA 面板不会自己拉模型。同步列表: bash deploy.sh cursor-bridge sync-models"
}

cmd_cursor_bridge_stop() {
    require_cursor_bridge_compose || return 1
    cursor_bridge_compose stop
    info "Cursor Bridge 已停止（未动 CPA）"
}

cmd_cursor_bridge_restart() {
    require_cursor_bridge_compose || return 1
    validate_cursor_bridge_env || return 1
    cursor_bridge_compose restart
    cursor_bridge_connect_cpa || true
    info "Cursor Bridge 已重启"
}

cmd_cursor_bridge_status() {
    require_cursor_bridge_compose || return 1
    cursor_bridge_compose ps
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        if docker inspect "${CONTAINER_NAME}" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -Fq "${CURSOR_BRIDGE_NETWORK}"; then
            info "${CONTAINER_NAME} 已在 ${CURSOR_BRIDGE_NETWORK}"
        else
            warn "${CONTAINER_NAME} 还没挂 ${CURSOR_BRIDGE_NETWORK}"
        fi
    fi
}

cmd_cursor_bridge_logs() {
    require_cursor_bridge_compose || return 1
    if [[ -n "${1:-}" ]]; then
        cursor_bridge_compose logs -f --tail 200 "$1"
    else
        cursor_bridge_compose logs -f --tail 200
    fi
}

cmd_cursor_bridge_doctor() {
    require_cursor_bridge_compose || return 1
    validate_cursor_bridge_env || return 1
    cursor_bridge_compose config --quiet || { error "Compose 校验失败"; return 1; }
    docker image inspect "${CURSOR_BRIDGE_IMAGE}" >/dev/null 2>&1 || { error "缺少钉死镜像 ${CURSOR_BRIDGE_IMAGE}"; return 1; }
    local user ports logs cursor_key bridge_key code
    user="$(docker inspect "${CURSOR_BRIDGE_CONTAINER_NAME}" --format '{{.Config.User}}' 2>/dev/null || true)"
    [[ "${user}" == "app" ]] || { error "cursor-bridge 必须以 user=app 运行"; return 1; }
    ports="$(docker port "${CURSOR_BRIDGE_CONTAINER_NAME}" 2>/dev/null || true)"
    printf '%s' "${ports}" | grep -Fq '0.0.0.0:' && { error "桥端口绑到了 0.0.0.0"; return 1; }
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        docker inspect "${CONTAINER_NAME}" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -Fq "${CURSOR_BRIDGE_NETWORK}" \
            || { error "CPA 未挂 ${CURSOR_BRIDGE_NETWORK}"; return 1; }
        code="$(docker exec "${CONTAINER_NAME}" wget -qS -O /dev/null "http://cursor-bridge:8765/v1/models" 2>&1 | awk '/HTTP\//{print $2}' | tail -1 || true)"
        if [[ -z "${code}" ]]; then
            code="$(docker exec "${CONTAINER_NAME}" curl -sS -o /dev/null -w '%{http_code}' "http://cursor-bridge:8765/v1/models" 2>/dev/null || true)"
        fi
        [[ "${code}" == "401" ]] || warn "无 Bearer 打桥应为 401，实际 ${code:-unknown}"
    fi
    cursor_key="$(cursor_bridge_env_value CURSOR_API_KEY)"
    bridge_key="$(cursor_bridge_env_value CURSOR_BRIDGE_API_KEY)"
    logs="$(docker logs "${CURSOR_BRIDGE_CONTAINER_NAME}" 2>&1 || true)"
    if [[ -n "${cursor_key}" && "${logs}" == *"${cursor_key}"* ]] || [[ -n "${bridge_key}" && "${logs}" == *"${bridge_key}"* ]]; then
        error "日志里出现了 key"
        return 1
    fi
    info "Cursor Bridge doctor PASS"
    cmd_cursor_bridge_status
}

cmd_cursor_bridge_uninstall() {
    require_cursor_bridge_compose || return 1
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        docker network disconnect "${CURSOR_BRIDGE_NETWORK}" "${CONTAINER_NAME}" 2>/dev/null || true
    fi
    cursor_bridge_compose down --remove-orphans
    info "Cursor Bridge 已卸载（未删 CPA 卷）"
    detail "若已追加 openai-compatibility，请从 config.yaml 删掉 cursor-bridge 段后 bash deploy.sh restart"
    if [[ -f "${CURSOR_BRIDGE_ENV_FILE}" ]] && confirm "是否删除包含密钥的 cursor-bridge.env？" "n"; then
        assert_regular_file "${CURSOR_BRIDGE_ENV_FILE}" || return 1
        rm -f "${CURSOR_BRIDGE_ENV_FILE}"
        info "cursor-bridge.env 已删除"
    fi
}

show_cursor_bridge_help() {
    echo ""
    echo -e "  ${BOLD}Cursor Bridge sidecar${NC}"
    echo -e "  bash deploy.sh cursor-bridge ${DIM}[action]${NC}"
    echo ""
    echo -e "    ${CYAN}start${NC}      缺 key 就提示输入，然后构建并启动（默认）"
    echo -e "    ${CYAN}init${NC}       生成 env，提示输入一把 Cursor key"
    echo -e "    ${CYAN}configure${NC}  更换 Cursor key，并重建桥容器"
    echo -e "    ${CYAN}stop${NC}       停止桥，不动 CPA"
    echo -e "    ${CYAN}restart${NC}    重启桥容器"
    echo -e "    ${CYAN}status${NC}     查看桥和挂网状态"
    echo -e "    ${CYAN}logs [服务]${NC} 查看日志"
    echo -e "    ${CYAN}build${NC}      重新构建钉死镜像"
    echo -e "    ${CYAN}doctor${NC}     检查钉死、端口、挂网、401"
    echo -e "    ${CYAN}sync-models${NC} 从桥 /v1/models 写入 config.yaml（可跟 id 列表）"
    echo -e "    ${CYAN}uninstall${NC}  拆桥；不删 CPA 卷"
    echo ""
    echo -e "  ${DIM}默认向导不会安装这座桥。执行 bash deploy.sh cursor-bridge，按提示粘贴一把 Cursor key。${NC}"
    echo ""
    echo -e "  ${BOLD}把桥上的模型写进 config.yaml:${NC}"
    echo -e "    ${DIM}CPA 面板不会自己拉 /v1/models。默认只有 cursor-auto。${NC}"
    echo -e "    bash deploy.sh cursor-bridge sync-models"
    echo -e "    ${DIM}# 只要几个模型${NC}"
    echo -e "    bash deploy.sh cursor-bridge sync-models auto,cursor-grok-4.6"
    echo -e "    ${DIM}脚本在桥容器里用已有 key 拉列表，只改 cursor-bridge 的 models:，然后重启 CPA。${NC}"
    echo -e "    ${DIM}auto 的别名仍是 cursor-auto；其它 id 原样当 alias。客户端继续用 CPA_API_KEY。${NC}"
    echo ""
    echo -e "  ${DIM}套餐额度请打开 cursor.com/dashboard。桥 HTTP 没有 /usage。chat 里的 usage 只是估算，不是 Cursor 账单。${NC}"
    echo ""
}

cmd_cursor_bridge() {
    local action="${1:-start}"
    [[ $# -gt 0 ]] && shift || true
    case "${action}" in
        start|deploy) cmd_cursor_bridge_start ;;
        init) cmd_cursor_bridge_init ;;
        configure) cmd_cursor_bridge_configure ;;
        build) cmd_cursor_bridge_build ;;
        stop) cmd_cursor_bridge_stop ;;
        restart) cmd_cursor_bridge_restart ;;
        status) cmd_cursor_bridge_status ;;
        logs) cmd_cursor_bridge_logs "${1:-}" ;;
        doctor) cmd_cursor_bridge_doctor ;;
        sync-models|sync) cmd_cursor_bridge_sync_models "${1:-}" ;;
        uninstall) cmd_cursor_bridge_uninstall ;;
        help|--help|-h) show_cursor_bridge_help ;;
        *) error "未知 Cursor Bridge 操作: ${action}"; show_cursor_bridge_help; return 1 ;;
    esac
}

# ========================== 帮助信息 ==========================================

show_help() {
    echo ""
    echo -e "  ${BOLD}CLI Proxy Manager${NC} v${VERSION}"
    echo -e "  ${DIM}一键部署和管理 CLIProxyAPI${NC}"
    echo ""
    echo -e "  ${BOLD}用法:${NC}"
    echo -e "    bash deploy.sh ${DIM}[命令]${NC}"
    echo ""
    echo -e "  ${BOLD}命令:${NC}"
    echo -e "    ${CYAN}(无参数)${NC}     交互式完整部署 (推荐首次使用)"
    echo -e "    ${CYAN}login${NC}        OAuth 登录 Provider"
    echo -e "    ${CYAN}logout${NC}       退出 Provider 账号"
    echo -e "    ${CYAN}start${NC}        启动服务"
    echo -e "    ${CYAN}stop${NC}         停止服务"
    echo -e "    ${CYAN}restart${NC}      重启服务"
    echo -e "    ${CYAN}status${NC}       查看服务状态"
    echo -e "    ${CYAN}logs${NC}         查看实时日志"
    echo -e "    ${CYAN}capabilities [--json]${NC} 只读 CPA 能力和暴露检查"
    echo -e "    ${CYAN}doctor${NC}       Doctor v2 只读诊断"
    echo -e "    ${CYAN}backup [文件]${NC} 备份配置和 OAuth 凭证"
    echo -e "    ${CYAN}restore <文件>${NC} 恢复配置和 OAuth 凭证"
    echo -e "    ${CYAN}check-update${NC}  只检查镜像是否有更新"
    echo -e "    ${CYAN}update${NC}       更新、健康检查，失败时自动回滚"
    echo -e "    ${CYAN}rollback${NC}     手动切换到上一个镜像版本"
    echo -e "    ${CYAN}auto-update${NC}  有新镜像时才更新（适合 cron）"
    echo -e "    ${CYAN}enable-auto-update [计划]${NC} 启用自动更新"
    echo -e "    ${CYAN}auto-update-status${NC} 查看自动更新状态"
    echo -e "    ${CYAN}disable-auto-update${NC} 禁用自动更新"
    echo -e "    ${CYAN}uninstall${NC}    完全卸载"
    echo -e "    ${CYAN}setup-claude${NC} 自动配置 Claude Code 环境"
    echo -e "    ${CYAN}sub2api [操作]${NC} 管理独立的 Sub2API 一键部署"
    echo -e "    ${CYAN}cursor-bridge [操作]${NC} 管理可选 Cursor Bridge sidecar"
    echo -e "    ${CYAN}help${NC}         显示此帮助"
    echo ""
    echo -e "  ${BOLD}环境变量:${NC}"
    echo -e "    ${CYAN}CPA_PORT${NC}     服务端口 (默认: 8317)"
    echo -e "    ${CYAN}CPA_API_KEY${NC}  API 密钥"
    echo -e "    ${CYAN}CPA_EXPOSURE_MODE${NC} 可选: public-proxy (仅用于能力分类)"
    echo ""
    echo -e "  ${BOLD}示例:${NC}"
    echo -e "    ${DIM}# 完整部署${NC}"
    echo -e "    bash deploy.sh"
    echo ""
    echo -e "    ${DIM}# 使用自定义端口${NC}"
    echo -e "    CPA_PORT=9000 bash deploy.sh start"
    echo ""
    echo -e "    ${DIM}# 自检并备份${NC}"
    echo -e "    bash deploy.sh capabilities --json"
    echo -e "    bash deploy.sh doctor"
    echo -e "    bash deploy.sh backup"
    echo ""
    echo -e "    ${DIM}# 一键部署独立 Sub2API 栈${NC}"
    echo -e "    bash deploy.sh sub2api deploy"
    echo ""
    echo -e "    ${DIM}# 一键部署可选 Cursor Bridge sidecar（会提示输入一把 Cursor key）${NC}"
    echo -e "    bash deploy.sh cursor-bridge"
    echo -e "    ${DIM}# 把桥上的模型列表写入 config.yaml（CPA 面板不会自己拉）${NC}"
    echo -e "    bash deploy.sh cursor-bridge sync-models"
    echo ""
    echo -e "    ${DIM}# 启用每日自动更新（默认 04:20）${NC}"
    echo -e "    bash deploy.sh enable-auto-update"
    echo -e "    bash deploy.sh enable-auto-update \"20 4 * * *\""
    echo ""
    echo -e "    ${DIM}# 远程一键安装${NC}"
    echo -e "    curl -fsSL https://raw.githubusercontent.com/MaykeZhs/cli-proxy-deploy/main/install.sh | bash"
    echo ""
}

# ========================== 入口 ==============================================

load_project_env() {
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$line" || "$line" == \#* ]] && continue
            [[ "$line" != *=* ]] && continue
            key="${line%%=*}"
            value="${line#*=}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            export "$key=$value"
        done < "${SCRIPT_DIR}/.env"
    fi
    CPA_PORT="${CPA_PORT:-8317}"
    CPA_API_KEY="${CPA_API_KEY:-}"
    CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY:-}"
    DOCKER_IMAGE="${CPA_IMAGE:-eceasy/cli-proxy-api:latest}"
}

main() {
    load_project_env
    case "${1:-}" in

        login)      cmd_login ;;
        logout)     cmd_logout ;;
        start)      cmd_start ;;
        stop)       cmd_stop ;;
        restart)    cmd_restart ;;
        status)     cmd_status ;;
        logs)       cmd_logs ;;
        capabilities) shift; cmd_capabilities "$@" ;;
        doctor)     cmd_doctor ;;
        backup)     shift; cmd_backup "${1:-}" ;;
        restore)    shift; cmd_restore "${1:-}" ;;
        check-update) cmd_check_update ;;
        update)     cmd_update ;;
        rollback)   cmd_rollback ;;
        auto-update) cmd_auto_update ;;
        enable-auto-update) shift; cmd_enable_auto_update "${1:-daily}" ;;
        auto-update-status) cmd_auto_update_status ;;
        disable-auto-update) cmd_disable_auto_update ;;
        uninstall)  cmd_uninstall ;;
        setup-claude) cmd_setup_claude ;;
        sub2api) shift; cmd_sub2api "$@" ;;
        cursor-bridge) shift; cmd_cursor_bridge "$@" ;;
        help|--help|-h) show_help ;;
        "")         cmd_deploy ;;
        *)          error "未知命令: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
