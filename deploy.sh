#!/usr/bin/env bash
# =============================================================================
#
#   ╔═══════════════════════════════════════════════════════════════════╗
#   ║   Antigravity Proxy — One-Click Deployment for CLIProxyAPI      ║
#   ║   反代 Antigravity，在 Claude Code / Cursor 等工具中使用            ║
#   ╚═══════════════════════════════════════════════════════════════════╝
#
#   用法:  bash deploy.sh          # 交互式完整部署
#          bash deploy.sh login    # 仅 OAuth 登录
#          bash deploy.sh logout   # 退出 Provider 账号
#          bash deploy.sh start    # 仅启动服务
#          bash deploy.sh stop     # 停止服务
#          bash deploy.sh status   # 查看状态
#          bash deploy.sh logs     # 实时日志
#          bash deploy.sh doctor   # 自检诊断
#          bash deploy.sh backup   # 备份配置和凭证
#          bash deploy.sh restore <file> # 恢复配置和凭证
#          bash deploy.sh check-update # 检查镜像更新
#          bash deploy.sh update   # 更新到最新版
#          bash deploy.sh auto-update # 有新镜像时才更新（适合 cron）
#          bash deploy.sh enable-auto-update [cron] # 启用每日自动更新
#          bash deploy.sh disable-auto-update # 禁用自动更新
#          bash deploy.sh uninstall # 完全卸载
#          bash deploy.sh setup-claude # 配置 Claude Code
#
# =============================================================================

if [ -z "${BASH_VERSION:-}" ] || [[ ":${SHELLOPTS:-}:" == *":posix:"* ]]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

# ========================== 常量 & 默认值 ====================================

readonly VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKER_IMAGE="eceasy/cli-proxy-api:latest"
readonly COMPOSE_PROJECT_NAME="antigravity-proxy"
export COMPOSE_PROJECT_NAME
readonly CONTAINER_NAME="antigravity-proxy"
readonly AUTH_VOLUME="antigravity-proxy-auth"
readonly OAUTH_PORT=51121
readonly CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly AUTO_UPDATE_LOG="${SCRIPT_DIR}/logs/auto-update.log"
readonly AUTO_UPDATE_MARKER_BEGIN="# >>> antigravity-proxy auto-update >>>"
readonly AUTO_UPDATE_MARKER_END="# <<< antigravity-proxy auto-update <<<"

# 用户可配置（在 .env 中覆盖）
CPA_PORT="${CPA_PORT:-8317}"
CPA_API_KEY="${CPA_API_KEY:-}"
CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY:-}"
API_KEYS=()

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

resolve_backup_path() {
    local requested="${1:-}"
    if [[ -z "$requested" ]]; then
        printf '%s/backups/antigravity-proxy-backup-%s.tgz' "${SCRIPT_DIR}" "$(date '+%Y%m%d-%H%M%S')"
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
    docker manifest inspect --verbose "${DOCKER_IMAGE}" 2>/dev/null \
        | awk -F'"' '/"digest"[[:space:]]*:/ { print $4; exit }'
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
        info "管理面板: ${GREEN}启用${NC}  密码: ${CYAN}${CPA_MANAGEMENT_KEY}${NC}"
    else
        CPA_MANAGEMENT_KEY=""
        info "管理面板: ${DIM}禁用${NC}"
    fi

    # Debug mode
    local debug_mode="false"
    if confirm "是否开启调试日志？(首次部署建议开启)" "y"; then
        debug_mode="true"
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
#  Antigravity Proxy 配置文件
#  由 deploy.sh 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

host: ""
port: 8317

auth-dir: "/root/.cli-proxy-api"

api-keys:
${api_keys_yaml}

debug: ${debug_mode}

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

    # 启动
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" up -d 2>&1 | tail -1

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
        echo -e "  面板密码  ${GREEN}${CPA_MANAGEMENT_KEY}${NC}"
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
    echo -e "  ${CYAN}bash deploy.sh update${NC}     更新到最新版本"
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
            show_result
            return 0
        fi

        warn "将覆盖现有 config.yaml 与全部 API key"
    fi

    config_wizard
    pull_image

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
    step "Doctor 自检"

    local failures=0
    local warnings=0
    local docker_ok=false
    local compose_ok=false
    local container_running=false
    local mapped_port="${CPA_PORT}"

    if command -v docker &>/dev/null; then
        info "Docker CLI 已安装"
    else
        error "未检测到 Docker CLI"
        failures=$((failures + 1))
    fi

    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        docker_ok=true
        info "Docker 守护进程运行中"
    else
        error "Docker 守护进程不可用"
        detail "请启动 Docker Desktop 后重试"
        failures=$((failures + 1))
    fi

    COMPOSE_CMD="$(detect_compose)"
    if [[ -n "${COMPOSE_CMD}" ]]; then
        compose_ok=true
        info "Docker Compose 可用 (${COMPOSE_CMD})"
    else
        error "Docker Compose 不可用"
        failures=$((failures + 1))
    fi

    if [[ -d "${CONFIG_FILE}" ]]; then
        error "config.yaml 当前是目录，不是文件"
        detail "请删除空目录后重新运行部署"
        failures=$((failures + 1))
    elif [[ -f "${CONFIG_FILE}" ]]; then
        local key_count
        key_count="$(config_api_key_count)"
        if [[ "${key_count:-0}" -gt 0 ]]; then
            info "config.yaml 存在，API key 数量: ${key_count}"
        else
            warn "config.yaml 存在，但未读取到 api-keys"
            warnings=$((warnings + 1))
        fi
    else
        error "config.yaml 不存在"
        detail "请先运行: bash deploy.sh"
        failures=$((failures + 1))
    fi

    if $compose_ok && [[ -f "${CONFIG_FILE}" ]]; then
        if (cd "${SCRIPT_DIR}" && CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" config --quiet); then
            info "docker-compose.yml 配置有效"
        else
            error "docker-compose.yml 配置检查失败"
            failures=$((failures + 1))
        fi
    fi

    if $docker_ok; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            container_running=true
            info "容器正在运行: ${CONTAINER_NAME}"
            local port_output
            port_output="$(docker port "${CONTAINER_NAME}" 8317/tcp 2>/dev/null | head -1 || true)"
            if [[ -n "${port_output}" ]]; then
                mapped_port="${port_output##*:}"
                info "端口映射正常: 127.0.0.1:${mapped_port}"
            else
                warn "未读取到容器端口映射，使用配置端口 ${CPA_PORT} 测试"
                warnings=$((warnings + 1))
            fi
        else
            warn "容器未运行"
            detail "可运行: bash deploy.sh start"
            warnings=$((warnings + 1))

            if command -v lsof &>/dev/null && lsof -i :"${CPA_PORT}" &>/dev/null 2>&1; then
                warn "端口 ${CPA_PORT} 已被占用"
                warnings=$((warnings + 1))
            else
                info "端口 ${CPA_PORT} 当前未被占用"
            fi
        fi

        if docker volume inspect "${AUTH_VOLUME}" &>/dev/null 2>&1; then
            local cred_count
            cred_count="$(docker run --rm -v "${AUTH_VOLUME}:/auth:ro" alpine sh -c "find /auth -maxdepth 1 -type f 2>/dev/null | grep -Ev '/(config|logs)$' | wc -l" 2>/dev/null | tr -d '[:space:]' || echo "0")"
            if [[ "${cred_count:-0}" -gt 0 ]]; then
                info "OAuth 凭证卷存在，凭证文件数: ${cred_count}"
            else
                warn "OAuth 凭证卷存在，但未找到 Provider 凭证"
                detail "可运行: bash deploy.sh login"
                warnings=$((warnings + 1))
            fi
        else
            warn "OAuth 凭证卷不存在"
            detail "完成 login 后会自动创建"
            warnings=$((warnings + 1))
        fi
    fi

    if $container_running; then
        sync_api_key_from_config
        if [[ -z "${CPA_API_KEY}" ]]; then
            error "无法读取 API key，跳过 /v1/models 测试"
            failures=$((failures + 1))
        else
            local body_file http_code curl_exit
            body_file="$(mktemp)"
            set +e
            http_code=$(curl -sS -o "${body_file}" -w "%{http_code}" \
                "http://127.0.0.1:${mapped_port}/v1/models" \
                -H "Authorization: Bearer ${CPA_API_KEY}" 2>/dev/null)
            curl_exit=$?
            set -e
            if [[ ${curl_exit} -ne 0 ]]; then
                http_code="000"
            fi

            if [[ "${http_code}" == "200" ]]; then
                if grep -q '"id"[[:space:]]*:' "${body_file}"; then
                    info "/v1/models 返回 200，且模型列表非空"
                else
                    warn "/v1/models 返回 200，但模型列表可能为空"
                    detail "通常表示 OAuth 登录未完成或凭证未加载"
                    warnings=$((warnings + 1))
                fi
            elif [[ "${http_code}" == "401" ]]; then
                error "/v1/models 认证失败 (401)"
                detail "请检查 config.yaml 中的 API key"
                failures=$((failures + 1))
            elif [[ "${http_code}" == "000" ]]; then
                warn "/v1/models 无响应"
                warnings=$((warnings + 1))
            else
                warn "/v1/models 返回异常状态: ${http_code}"
                warnings=$((warnings + 1))
            fi
            rm -f "${body_file}"
        fi
    fi

    echo ""
    divider
    if [[ "${failures}" -eq 0 ]]; then
        info "Doctor 完成: ${warnings} 个警告，0 个错误"
    else
        error "Doctor 完成: ${warnings} 个警告，${failures} 个错误"
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
        detail "用法: bash deploy.sh restore backups/antigravity-proxy-backup-YYYYmmdd-HHMMSS.tgz"
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
    docker pull "${DOCKER_IMAGE}" 2>&1 | tail -1
    cd "${SCRIPT_DIR}"
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" up -d 2>&1 | tail -1
    info "已更新到最新版本"
}

cmd_auto_update() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }
    require_config_file

    step "自动更新检查"
    detail "${DOCKER_IMAGE}"
    detail "时间: $(date '+%Y-%m-%d %H:%M:%S')"

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

    cd "${SCRIPT_DIR}"
    docker pull "${DOCKER_IMAGE}" 2>&1 | tail -1
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" up -d 2>&1 | tail -1

    local updated_digest
    updated_digest="$(get_local_image_digest || true)"
    if [[ -n "${updated_digest}" ]]; then
        info "自动更新完成"
        detail "当前 digest: ${updated_digest}"
    else
        warn "自动更新命令已完成，但未读取到本地镜像 digest"
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

cmd_enable_auto_update() {
    local schedule="${1:-20 4 * * *}"

    if ! command -v crontab &>/dev/null; then
        error "未检测到 crontab"
        detail "请先安装 cron/cronie 后重试"
        return 1
    fi

    if ! [[ "${schedule}" =~ ^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+$ ]]; then
        error "cron 表达式格式不正确"
        detail "示例: bash deploy.sh enable-auto-update \"20 4 * * *\""
        return 1
    fi

    require_config_file
    mkdir -p "$(dirname "${AUTO_UPDATE_LOG}")"

    local quoted_script_dir quoted_log cron_line
    quoted_script_dir="$(shell_quote "${SCRIPT_DIR}")"
    quoted_log="$(shell_quote "${AUTO_UPDATE_LOG}")"
    cron_line="${schedule} cd ${quoted_script_dir} && bash deploy.sh auto-update >> ${quoted_log} 2>&1"

    local existing
    existing="$(current_crontab_without_auto_update)"

    {
        [[ -n "${existing}" ]] && printf '%s\n' "${existing}"
        printf '%s\n' "${AUTO_UPDATE_MARKER_BEGIN}"
        printf '%s\n' "${cron_line}"
        printf '%s\n' "${AUTO_UPDATE_MARKER_END}"
    } | crontab -

    info "已启用自动更新"
    detail "计划: ${schedule}"
    detail "日志: ${AUTO_UPDATE_LOG}"
    detail "命令: bash deploy.sh auto-update"
}

cmd_disable_auto_update() {
    if ! command -v crontab &>/dev/null; then
        error "未检测到 crontab"
        return 1
    fi

    local existing
    existing="$(current_crontab_without_auto_update)"

    {
        [[ -n "${existing}" ]] && printf '%s\n' "${existing}"
    } | crontab -

    info "已禁用自动更新"
}

cmd_uninstall() {
    COMPOSE_CMD="$(detect_compose)"
    [[ -z "$COMPOSE_CMD" ]] && { error "Docker Compose 不可用"; exit 1; }

    echo ""
    warn "即将完全卸载 Antigravity Proxy"
    echo ""

    if ! confirm "确认卸载？(这将删除容器、凭证卷和配置文件)" "n"; then
        info "取消卸载"
        return 0
    fi

    cd "${SCRIPT_DIR}"
    CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
    docker volume rm "${AUTH_VOLUME}" 2>/dev/null || true

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

# ========================== 帮助信息 ==========================================

show_help() {
    echo ""
    echo -e "  ${BOLD}Antigravity Proxy${NC} v${VERSION}"
    echo -e "  ${DIM}一键部署 CLIProxyAPI 反代 Antigravity${NC}"
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
    echo -e "    ${CYAN}doctor${NC}       自检 Docker/配置/凭证/API"
    echo -e "    ${CYAN}backup [文件]${NC} 备份配置和 OAuth 凭证"
    echo -e "    ${CYAN}restore <文件>${NC} 恢复配置和 OAuth 凭证"
    echo -e "    ${CYAN}check-update${NC}  只检查镜像是否有更新"
    echo -e "    ${CYAN}update${NC}       更新到最新版本"
    echo -e "    ${CYAN}auto-update${NC}  有新镜像时才更新（适合 cron）"
    echo -e "    ${CYAN}enable-auto-update [cron]${NC} 启用自动更新"
    echo -e "    ${CYAN}disable-auto-update${NC} 禁用自动更新"
    echo -e "    ${CYAN}uninstall${NC}    完全卸载"
    echo -e "    ${CYAN}setup-claude${NC} 自动配置 Claude Code 环境"
    echo -e "    ${CYAN}help${NC}         显示此帮助"
    echo ""
    echo -e "  ${BOLD}环境变量:${NC}"
    echo -e "    ${CYAN}CPA_PORT${NC}     服务端口 (默认: 8317)"
    echo -e "    ${CYAN}CPA_API_KEY${NC}  API 密钥"
    echo ""
    echo -e "  ${BOLD}示例:${NC}"
    echo -e "    ${DIM}# 完整部署${NC}"
    echo -e "    bash deploy.sh"
    echo ""
    echo -e "    ${DIM}# 使用自定义端口${NC}"
    echo -e "    CPA_PORT=9000 bash deploy.sh start"
    echo ""
    echo -e "    ${DIM}# 自检并备份${NC}"
    echo -e "    bash deploy.sh doctor"
    echo -e "    bash deploy.sh backup"
    echo ""
    echo -e "    ${DIM}# 启用每日自动更新（默认 04:20）${NC}"
    echo -e "    bash deploy.sh enable-auto-update"
    echo -e "    bash deploy.sh enable-auto-update \"20 4 * * *\""
    echo ""
    echo -e "    ${DIM}# 远程一键安装${NC}"
    echo -e "    curl -fsSL https://raw.githubusercontent.com/MaykeZhs/antigravity-proxy/main/install.sh | bash"
    echo ""
}

# ========================== 入口 ==============================================

main() {
    # 加载 .env（逐行解析，不 source，避免代码注入）
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

    case "${1:-}" in
        login)      cmd_login ;;
        logout)     cmd_logout ;;
        start)      cmd_start ;;
        stop)       cmd_stop ;;
        restart)    cmd_restart ;;
        status)     cmd_status ;;
        logs)       cmd_logs ;;
        doctor)     cmd_doctor ;;
        backup)     shift; cmd_backup "${1:-}" ;;
        restore)    shift; cmd_restore "${1:-}" ;;
        check-update) cmd_check_update ;;
        update)     cmd_update ;;
        auto-update) cmd_auto_update ;;
        enable-auto-update) shift; cmd_enable_auto_update "$*" ;;
        disable-auto-update) cmd_disable_auto_update ;;
        uninstall)  cmd_uninstall ;;
        setup-claude) cmd_setup_claude ;;
        help|--help|-h) show_help ;;
        "")         cmd_deploy ;;
        *)          error "未知命令: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
