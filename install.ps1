#!/usr/bin/env pwsh
# =============================================================================
#  Antigravity Proxy — Remote One-Click Installer (Windows)
#  远程一键安装脚本 (Windows)
#
#  Usage / 用法:
#    Invoke-WebRequest -Uri https://raw.githubusercontent.com/MaykeZhs/antigravity-proxy/main/install.ps1 | Invoke-Expression
#    $env:REPO_URL='https://github.com/MaykeZhs/antigravity-proxy'; .\install.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'

$REPO_URL    = if ($env:REPO_URL)    { $env:REPO_URL }    else { 'https://github.com/MaykeZhs/antigravity-proxy' }
$INSTALL_DIR = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $env:USERPROFILE '.antigravity-proxy' }
$BRANCH      = if ($env:BRANCH)      { $env:BRANCH }      else { 'main' }

function info($msg)  { Write-Host "  ✔  $msg" -ForegroundColor Green }
function error-msg($msg) { Write-Host "  ✘  $msg" -ForegroundColor Red }

Write-Host ''
Write-Host '  Antigravity Proxy — Installer' -ForegroundColor Cyan
Write-Host '  One-click CLIProxyAPI deployment for Antigravity' -ForegroundColor DarkGray
Write-Host ''

# Check git
try { $null = Get-Command git -ErrorAction Stop }
catch {
    error-msg 'git is not installed / git 未安装'
    Write-Host '     https://git-scm.com/downloads'
    exit 1
}

# Check Docker
try { $null = Get-Command docker -ErrorAction Stop }
catch {
    error-msg 'Docker is not installed / Docker 未安装'
    Write-Host '     https://www.docker.com/products/docker-desktop/'
    exit 1
}

# Clone or update
if (Test-Path $INSTALL_DIR -PathType Container) {
    info 'Updating existing installation... / 更新已有安装...'
    Push-Location $INSTALL_DIR
    try { git pull origin $BRANCH --quiet } finally { Pop-Location }
} else {
    info 'Cloning repository... / 克隆仓库...'
    git clone --depth 1 -b $BRANCH "$REPO_URL.git" $INSTALL_DIR
}

Write-Host ''
info "Installed to / 安装到: $INSTALL_DIR"
Write-Host ''
Write-Host '  Next step / 下一步:' -ForegroundColor White
Write-Host "  cd $INSTALL_DIR; .\deploy.ps1" -ForegroundColor Cyan
Write-Host ''

# Auto-run deploy
Write-Host '  Run deployment now? / 立即开始部署？ [Y/n]: ' -ForegroundColor Magenta -NoNewline
$answer = (Read-Host).Trim()
if (-not $answer) { $answer = 'y' }

if ($answer -match '^[Yy]') {
    & (Join-Path $INSTALL_DIR 'deploy.ps1')
}
