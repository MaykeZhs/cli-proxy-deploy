#!/usr/bin/env bash
# =============================================================================
#
#   Antigravity Proxy — 自动更新定时任务开关 (auto-update)
#   通过 cron 定时运行 `deploy.sh update`，让镜像保持最新。
#   只有镜像真的有更新时才会重建容器；无更新则为空操作、不会重启。
#
#   用法:
#     bash auto-update.sh enable [计划]   # 开启定时自动更新
#     bash auto-update.sh disable         # 关闭定时自动更新
#     bash auto-update.sh status          # 查看状态与最近日志
#     bash auto-update.sh doctor          # 自检：定时任务为什么没执行
#     bash auto-update.sh run             # 立即执行一次（cron 调用此命令）
#
#   计划 (可选, 默认 daily):
#     daily   每天 05:00              (0 5 * * *)
#     12h     每天 05:00 与 17:00     (0 5,17 * * *)
#     6h      每 6 小时               (0 */6 * * *)
#     hourly  每小时                  (0 * * * *)
#     weekly  每周一 05:00            (0 5 * * 1)
#     "m h dom mon dow"   自定义 5 段 cron 表达式
#
#   日志默认写入 /var/log/cpa-update.log，可用环境变量 CPA_UPDATE_LOG 覆盖。
#
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy.sh"
readonly SELF="${SCRIPT_DIR}/auto-update.sh"
readonly LOG_FILE="${CPA_UPDATE_LOG:-/var/log/cpa-update.log}"
readonly CRON_MARKER="# antigravity-proxy-auto-update"
readonly DOCKER_IMAGE="eceasy/cli-proxy-api:latest"

# ========================== 颜色 & 日志 ======================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

info()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error()  { echo -e "  ${RED}✘${NC}  $*"; }
step()   { echo ""; echo -e "  ${BLUE}${BOLD}▸ $*${NC}"; }
detail() { echo -e "     ${DIM}$*${NC}"; }

# ========================== 工具函数 ==========================================

# 把计划关键字解析为 cron 表达式；非法返回 __INVALID__
resolve_schedule() {
    case "$1" in
        daily)  echo "0 5 * * *" ;;
        12h)    echo "0 5,17 * * *" ;;
        6h)     echo "0 */6 * * *" ;;
        hourly) echo "0 * * * *" ;;
        weekly) echo "0 5 * * 1" ;;
        *)
            if [[ "$(echo "$1" | awk '{print NF}')" == "5" ]]; then
                echo "$1"
            else
                echo "__INVALID__"
            fi
            ;;
    esac
}

get_crontab() { crontab -l 2>/dev/null || true; }

require_cron() {
    if ! command -v crontab &>/dev/null; then
        error "未检测到 crontab，请先安装 cron"
        detail "Debian/Ubuntu: apt-get install -y cron"
        detail "CentOS/RHEL:   yum install -y cronie"
        exit 1
    fi
}

cron_running() {
    pgrep -x cron &>/dev/null || pgrep -x crond &>/dev/null
}

# ========================== 命令实现 ==========================================

cmd_enable() {
    require_cron
    [[ -f "$DEPLOY_SCRIPT" ]] || { error "未找到 deploy.sh: ${DEPLOY_SCRIPT}"; exit 1; }

    local arg="${1:-daily}"
    local expr; expr="$(resolve_schedule "$arg")"
    if [[ "$expr" == "__INVALID__" ]]; then
        error "无法识别的计划: ${arg}"
        detail "可用: daily | 12h | 6h | hourly | weekly | \"m h dom mon dow\""
        exit 1
    fi

    # 用 marker 注释做幂等：先剔除旧的本任务行，再追加新行
    local line="${expr} /usr/bin/env bash \"${SELF}\" run ${CRON_MARKER}"
    local existing; existing="$(get_crontab | grep -v -F "$CRON_MARKER" || true)"
    { [[ -n "$existing" ]] && printf '%s\n' "$existing"; printf '%s\n' "$line"; } | crontab -

    step "已开启自动更新"
    info "计划: ${BOLD}${arg}${NC}  ${DIM}(cron: ${expr})${NC}"
    detail "镜像: ${DOCKER_IMAGE}"
    detail "日志: ${LOG_FILE}"
    detail "只有镜像有更新时才会重建容器，无更新不重启"
    if ! cron_running; then
        echo ""
        warn "cron 服务似乎未运行，定时任务不会触发"
        detail "启动: systemctl enable --now cron   (RHEL 系为 crond)"
    fi
}

cmd_disable() {
    require_cron
    if ! get_crontab | grep -q -F "$CRON_MARKER"; then
        warn "当前未启用自动更新，无需关闭"
        return 0
    fi
    local existing; existing="$(get_crontab | grep -v -F "$CRON_MARKER" || true)"
    if [[ -n "$existing" ]]; then
        printf '%s\n' "$existing" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi
    info "已关闭自动更新"
}

cmd_status() {
    require_cron
    step "自动更新状态"
    local entry; entry="$(get_crontab | grep -F "$CRON_MARKER" || true)"
    if [[ -n "$entry" ]]; then
        info "状态: ${GREEN}已启用${NC}"
        detail "计划(cron): $(echo "$entry" | awk '{print $1,$2,$3,$4,$5}')"
        cron_running || warn "但 cron 服务未运行，任务不会触发 (systemctl enable --now cron)"
    else
        warn "状态: 未启用"
        detail "开启: ${CYAN}bash auto-update.sh enable${NC}"
    fi
    detail "日志: ${LOG_FILE}"
    if [[ -s "$LOG_FILE" ]]; then
        echo ""
        detail "最近日志:"
        tail -n 8 "$LOG_FILE" | sed 's/^/       /'
    fi
}

cmd_doctor() {
    require_cron
    step "自动更新自检 (doctor)"

    # 1) crontab 条目是否存在
    local entry; entry="$(get_crontab | grep -F "$CRON_MARKER" || true)"
    if [[ -n "$entry" ]]; then
        info "crontab 条目: ${GREEN}已安装${NC}"
        detail "计划(cron): $(echo "$entry" | awk '{print $1,$2,$3,$4,$5}')"
    else
        error "crontab 条目: 未找到  →  先运行 ${CYAN}bash auto-update.sh enable${NC}"
    fi

    # 2) cron 服务是否在跑
    if cron_running; then
        info "cron 服务: ${GREEN}运行中${NC}"
    else
        error "cron 服务: 未运行  →  ${CYAN}systemctl enable --now cron${NC} (RHEL 系为 crond)"
    fi

    # 3) 用户与时区（最常见的坑）
    detail "当前用户: $(id -un)   ${DIM}crontab 按用户隔离，务必用同一账号 enable 与查看${NC}"
    detail "系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')   ${DIM}cron 按系统本地时区触发${NC}"

    # 4) 依赖
    if command -v docker &>/dev/null; then
        info "docker: $(command -v docker)"
    else
        warn "docker 不在当前 PATH（run 时脚本会补全 PATH，通常无碍）"
    fi
    [[ -f "$DEPLOY_SCRIPT" ]] && info "deploy.sh: 存在" || error "deploy.sh: 缺失 (${DEPLOY_SCRIPT})"

    # 5) 日志
    if [[ -s "$LOG_FILE" ]]; then
        info "日志: ${LOG_FILE}"
        detail "最近记录:"
        tail -n 6 "$LOG_FILE" | sed 's/^/       /'
    else
        warn "日志为空或不存在: ${LOG_FILE}  ${DIM}（可能还没到触发时间，或从未执行）${NC}"
    fi

    # 6) 让系统告诉你它有没有真的触发过本任务
    echo ""
    detail "确认系统是否真触发过(按发行版择一):"
    detail "  ${CYAN}grep CRON /var/log/syslog | tail${NC}        # Debian/Ubuntu"
    detail "  ${CYAN}journalctl -u cron --since today${NC}        # systemd"
    detail "  ${CYAN}grep CRON /var/log/cron | tail${NC}          # CentOS/RHEL"
    echo ""
    warn "最常见原因: 刚 enable 不久、还没到下一个触发点(如每天 05:00)。"
    detail "想立刻验证可手动跑:  ${CYAN}bash auto-update.sh run${NC}  然后  ${CYAN}bash auto-update.sh status${NC}"
}

cmd_run() {
    # cron 环境 PATH 很精简，显式补全以保证能找到 docker
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
    local dir; dir="$(dirname "$LOG_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || true
    {
        echo "========== $(date '+%Y-%m-%d %H:%M:%S') 自动更新开始 =========="
        bash "$DEPLOY_SCRIPT" update
        echo "---- 清理悬空镜像 ----"
        docker image prune -f
        echo "========== $(date '+%Y-%m-%d %H:%M:%S') 自动更新结束 =========="
        echo ""
    } >> "$LOG_FILE" 2>&1
    # 日志只保留最近 2000 行，避免无限增长
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
    fi
}

show_help() {
    echo ""
    echo -e "  ${BOLD}Antigravity Proxy 自动更新开关${NC}"
    echo ""
    echo -e "  ${CYAN}bash auto-update.sh enable [计划]${NC}   开启定时自动更新"
    echo -e "  ${CYAN}bash auto-update.sh disable${NC}         关闭定时自动更新"
    echo -e "  ${CYAN}bash auto-update.sh status${NC}          查看状态与最近日志"
    echo -e "  ${CYAN}bash auto-update.sh doctor${NC}          自检定时任务为何没执行"
    echo -e "  ${CYAN}bash auto-update.sh run${NC}             立即执行一次更新"
    echo ""
    echo -e "  计划: ${DIM}daily(默认) | 12h | 6h | hourly | weekly | \"m h dom mon dow\"${NC}"
    echo ""
}

# ========================== 入口 ==============================================

case "${1:-}" in
    enable)  shift; cmd_enable "${1:-daily}" ;;
    disable) cmd_disable ;;
    status)  cmd_status ;;
    doctor)  cmd_doctor ;;
    run)     cmd_run ;;
    help|--help|-h|"") show_help ;;
    *) error "未知命令: $1"; show_help; exit 1 ;;
esac
