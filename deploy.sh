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
#          bash deploy.sh update   # 更新到最新版
#          bash deploy.sh uninstall # 完全卸载
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

# 用户可配置（在 .env 中覆盖）
CPA_PORT="${CPA_PORT:-8317}"
CPA_API_KEY="${CPA_API_KEY:-}"
CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY:-}"

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
    echo "sk-$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 32)"
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
    ask "设置 API 密钥 (用于客户端认证)" "${default_key}"
    read -r input_key
    CPA_API_KEY="${input_key:-$default_key}"
    info "API 密钥: ${CYAN}${CPA_API_KEY}${NC}"

    # Port
    ask "服务端口" "${CPA_PORT}"
    read -r input_port
    CPA_PORT="${input_port:-$CPA_PORT}"
    info "服务端口: ${CYAN}${CPA_PORT}${NC}"

    # Management panel
    if confirm "是否启用管理面板？" "y"; then
        local default_mgmt_key
        default_mgmt_key="$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 16)"
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
    cat > "${CONFIG_FILE}" << YAML
# =============================================================================
#  Antigravity Proxy 配置文件
#  由 deploy.sh 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

host: ""
port: 8317

auth-dir: "/root/.cli-proxy-api"

api-keys:
  - "${CPA_API_KEY}"

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
        -v "${CONFIG_FILE}:/CLIProxyAPI/config.yaml:ro" \
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
    echo ""
    echo -e "  ${GREEN}${BOLD}🎉 部署完成！${NC}"
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}服务信息${NC}"
    echo -e "  代理地址  ${GREEN}http://127.0.0.1:${CPA_PORT}${NC}"
    echo -e "  API 密钥  ${GREEN}${CPA_API_KEY}${NC}"
    if [[ -n "${CPA_MANAGEMENT_KEY}" ]]; then
        echo -e "  管理面板  ${GREEN}http://127.0.0.1:${CPA_PORT}/panel${NC}"
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
    echo -e "  ${CYAN}bash deploy.sh update${NC}     更新到最新版本"
    echo -e "  ${CYAN}bash deploy.sh login${NC}      重新 OAuth 登录"
    echo -e "  ${CYAN}bash deploy.sh logout${NC}     退出 Provider 账号"
    echo -e "  ${CYAN}bash deploy.sh uninstall${NC}  完全卸载"
    echo ""
}

# ========================== 子命令实现 ========================================

cmd_deploy() {
    banner
    check_prereqs
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
    if [[ -f "${CONFIG_FILE}" ]] && [[ -z "${CPA_API_KEY}" ]]; then
        CPA_API_KEY=$(grep -A1 'api-keys:' "${CONFIG_FILE}" 2>/dev/null | tail -1 | sed 's/.*- *"\(.*\)"/\1/' || echo "")
    fi

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
        if [[ -f "${CONFIG_FILE}" ]] && [[ -z "${CPA_API_KEY}" ]]; then
            CPA_API_KEY=$(grep -A1 'api-keys:' "${CONFIG_FILE}" 2>/dev/null | tail -1 | sed 's/.*- *"\(.*\)"/\1/' || echo "dummy")
        fi

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
    echo -e "    ${CYAN}update${NC}       更新到最新版本"
    echo -e "    ${CYAN}uninstall${NC}    完全卸载"
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
        update)     cmd_update ;;
        uninstall)  cmd_uninstall ;;
        help|--help|-h) show_help ;;
        "")         cmd_deploy ;;
        *)          error "未知命令: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
