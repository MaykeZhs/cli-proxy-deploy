#!/usr/bin/env bash
# =============================================================================
#  Antigravity Proxy — Remote One-Click Installer
#  远程一键安装脚本
#
#  Usage / 用法:
#    curl -fsSL https://raw.githubusercontent.com/YOUR_USER/antigravity-proxy/main/install.sh | bash
#    REPO_URL=https://github.com/YOUR_USER/antigravity-proxy bash install.sh
# =============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/YOUR_USER/antigravity-proxy}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.antigravity-proxy}"
BRANCH="${BRANCH:-main}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "  ${GREEN}✔${NC}  $*"; }
error() { echo -e "  ${RED}✘${NC}  $*"; }

echo ""
echo -e "  ${CYAN}${BOLD}Antigravity Proxy — Installer${NC}"
echo -e "  ${DIM}One-click CLIProxyAPI deployment for Antigravity${NC}"
echo ""

# Check git
if ! command -v git &>/dev/null; then
    error "git is not installed / git 未安装"
    exit 1
fi

# Check Docker
if ! command -v docker &>/dev/null; then
    error "Docker is not installed / Docker 未安装"
    echo "     https://www.docker.com/products/docker-desktop/"
    exit 1
fi

# Clone or update
if [[ -d "${INSTALL_DIR}" ]]; then
    info "Updating existing installation... / 更新已有安装..."
    cd "${INSTALL_DIR}"
    git pull origin "${BRANCH}" --quiet
else
    info "Cloning repository... / 克隆仓库..."
    git clone --depth 1 -b "${BRANCH}" "${REPO_URL}.git" "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"
fi

chmod +x deploy.sh

echo ""
info "Installed to / 安装到: ${CYAN}${INSTALL_DIR}${NC}"
echo ""
echo -e "  ${BOLD}Next step / 下一步:${NC}"
echo -e "  ${CYAN}cd ${INSTALL_DIR} && bash deploy.sh${NC}"
echo ""

# Auto-run deploy
echo -en "  Run deployment now? / 立即开始部署？ ${DIM}[Y/n]${NC}: "
read -r answer
answer="${answer:-y}"

if [[ "$answer" =~ ^[Yy] ]]; then
    exec bash "${INSTALL_DIR}/deploy.sh"
fi
