#!/usr/bin/env pwsh
# =============================================================================
#
#   ╔═══════════════════════════════════════════════════════════════════╗
#   ║   Antigravity Proxy — One-Click Deployment for CLIProxyAPI      ║
#   ║   反代 Antigravity，在 Claude Code / Cursor 等工具中使用            ║
#   ╚═══════════════════════════════════════════════════════════════════╝
#
#   用法:  .\deploy.ps1          # 交互式完整部署
#          .\deploy.ps1 login    # 仅 OAuth 登录
#          .\deploy.ps1 start    # 仅启动服务
#          .\deploy.ps1 stop     # 停止服务
#          .\deploy.ps1 status   # 查看状态
#          .\deploy.ps1 logs     # 实时日志
#          .\deploy.ps1 update   # 更新到最新版
#          .\deploy.ps1 uninstall # 完全卸载
#
# =============================================================================

$ErrorActionPreference = 'Stop'

# ========================== 常量 & 默认值 ====================================

$script:VERSION        = '1.0.0'
$script:SCRIPT_DIR     = $PSScriptRoot
$script:DOCKER_IMAGE   = 'eceasy/cli-proxy-api:latest'
$script:COMPOSE_PROJECT_NAME = 'antigravity-proxy'
$env:COMPOSE_PROJECT_NAME    = $script:COMPOSE_PROJECT_NAME
$script:CONTAINER_NAME = 'antigravity-proxy'
$script:AUTH_VOLUME    = 'antigravity-proxy-auth'
$script:OAUTH_PORT     = 51121
$script:CONFIG_FILE    = Join-Path $script:SCRIPT_DIR 'config.yaml'
$script:COMPOSE_FILE   = Join-Path $script:SCRIPT_DIR 'docker-compose.yml'

# 用户可配置（在 .env 中覆盖）
$script:CPA_PORT           = if ($env:CPA_PORT)           { $env:CPA_PORT }           else { '8317' }
$script:CPA_API_KEY        = if ($env:CPA_API_KEY)        { $env:CPA_API_KEY }        else { '' }
$script:CPA_MANAGEMENT_KEY = if ($env:CPA_MANAGEMENT_KEY) { $env:CPA_MANAGEMENT_KEY } else { '' }

# ========================== 颜色 & 样式 ======================================

$script:UseColor = $false
try {
    if ($Host.UI.RawUI -and $Host.UI.RawUI.WindowSize.Width -gt 0) {
        $script:UseColor = $true
    }
} catch { }

function Write-Color($text, $color) {
    if ($script:UseColor) { Write-Host $text -ForegroundColor $color -NoNewline }
    else { Write-Host $text -NoNewline }
}

# ========================== 日志函数 ==========================================

function banner {
    Write-Host ''
    Write-Color @"
     _          _   _                       _ _
    / \   _ __ | |_(_) __ _ _ __ __ ___   _(_) |_ _   _
   / _ \ | '_ \| __| |/ _` | '__/ _` \ \ / / | __| | | |
  / ___ \| | | | |_| | (_| | | | (_| |\ V /| | |_| |_| |
 /_/   \_\_| |_|\__|_|\__, |_|  \__,_| \_/ |_|\__|\__, |
                       |___/    Proxy               |___/
"@ Cyan
    Write-Host ''
    Write-Host "  Powered by CLIProxyAPI · v$script:VERSION" -ForegroundColor DarkGray
    Write-Host ''
}

function info($msg)    { Write-Host "  ✔  $msg" -ForegroundColor Green }
function warn($msg)    { Write-Host "  ⚠  $msg" -ForegroundColor Yellow }
function error-msg($msg) { Write-Host "  ✘  $msg" -ForegroundColor Red }
function step($msg)    { Write-Host ''; Write-Host "  ▸ $msg" -ForegroundColor Blue }
function detail($msg)  { Write-Host "     $msg" -ForegroundColor DarkGray }
function divider       { Write-Host '  ──────────────────────────────────────────' -ForegroundColor DarkGray }

function ask($prompt, $default = '') {
    if ($default) {
        Write-Host "  ?  $prompt [$default]: " -ForegroundColor Magenta -NoNewline
    } else {
        Write-Host "  ?  ${prompt}: " -ForegroundColor Magenta -NoNewline
    }
}

function confirm-prompt($prompt, $default = 'y') {
    if ($default -eq 'y') {
        Write-Host "  ?  $prompt [Y/n]: " -ForegroundColor Magenta -NoNewline
    } else {
        Write-Host "  ?  $prompt [y/N]: " -ForegroundColor Magenta -NoNewline
    }
    $answer = (Read-Host).Trim()
    if (-not $answer) { $answer = $default }
    return $answer -match '^[Yy]'
}

# ========================== 环境检测 ==========================================

function detect-compose {
    try {
        $null = docker compose version 2>$null
        if ($LASTEXITCODE -eq 0) { return 'docker compose' }
    } catch { }
    try {
        $null = Get-Command docker-compose -ErrorAction SilentlyContinue
        if ($?) { return 'docker-compose' }
    } catch { }
    return ''
}

function Invoke-Compose {
    $cmdParts = $script:COMPOSE_CMD -split '\s+'
    if ($cmdParts.Count -gt 1) {
        & $cmdParts[0] $cmdParts[1] @args
    } else {
        & $cmdParts[0] @args
    }
}

function check-prereqs {
    step '检查运行环境'

    # Docker
    try { $null = Get-Command docker -ErrorAction Stop }
    catch {
        error-msg '未检测到 Docker'
        Write-Host ''
        Write-Host '     请先安装 Docker Desktop:'
        Write-Host '     https://www.docker.com/products/docker-desktop/'
        Write-Host ''
        exit 1
    }
    info 'Docker 已安装'

    # Docker daemon
    $daemonOk = $false
    $dockerInfoOutput = @()
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $dockerInfoOutput = docker info 2>&1
        if ($LASTEXITCODE -eq 0) { $daemonOk = $true }
    } catch {
        $dockerInfoOutput = @($_.Exception.Message)
    } finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
    if (-not $daemonOk) {
        error-msg 'Docker 守护进程不可用'
        $dockerInfoOutput |
            Where-Object { $_ -match 'denied|cannot connect|docker_engine|error|failed|未运行|拒绝' } |
            Select-Object -First 3 |
            ForEach-Object { detail $_ }
        Write-Host '     请确认 Docker Desktop 已启动，并且当前用户有权限访问 Docker。'
        exit 1
    }
    info 'Docker 守护进程运行中'

    # Docker Compose
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) {
        error-msg '未检测到 Docker Compose'
        exit 1
    }
    info 'Docker Compose 可用'

    # Port check
    $portInUse = $false
    try {
        $conn = Get-NetTCPConnection -LocalPort ([int]$script:CPA_PORT) -ErrorAction SilentlyContinue
        if ($conn) { $portInUse = $true }
    } catch { }

    if ($portInUse) {
        $containerNames = docker ps --format '{{.Names}}' 2>$null
        if ($containerNames -and ($containerNames -match "^$script:CONTAINER_NAME$")) {
            warn "端口 $($script:CPA_PORT) 被本项目容器占用（将自动重建）"
        } else {
            error-msg "端口 $($script:CPA_PORT) 已被其他程序占用"
            detail '请修改 CPA_PORT 环境变量或停止占用端口的程序'
            exit 1
        }
    } else {
        info "端口 $($script:CPA_PORT) 可用"
    }
}

# ========================== 交互式配置向导 ====================================

function generate-key {
    $chars = @(48..57) + @(65..90) + @(97..122)
    $rng = -join ($chars | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    return "sk-$rng"
}

function ensure-config-file-slot {
    if (-not (Test-Path $script:CONFIG_FILE -PathType Container)) {
        return
    }

    warn '检测到 config.yaml 是目录，不是配置文件'
    detail '这通常是先运行 docker compose up，导致 Docker 自动创建了同名目录'

    $items = Get-ChildItem $script:CONFIG_FILE -ErrorAction SilentlyContinue
    if ($items -and $items.Count -gt 0) {
        error-msg 'config.yaml 目录不是空的，请先手动检查后再处理'
        detail "路径: $($script:CONFIG_FILE)"
        exit 1
    }

    if (confirm-prompt '是否删除这个空目录并重新生成 config.yaml 文件？' 'y') {
        Remove-Item $script:CONFIG_FILE -Force
        info '已删除空目录: config.yaml'
    } else {
        detail '可手动执行: Remove-Item config.yaml'
        exit 1
    }
}

function require-config-file {
    if (Test-Path $script:CONFIG_FILE -PathType Container) {
        error-msg '配置路径错误: config.yaml 当前是目录，不是文件'
        detail '请运行: .\deploy.ps1'
        detail '或手动执行: Remove-Item config.yaml; Copy-Item config.example.yaml config.yaml'
        exit 1
    }

    if (-not (Test-Path $script:CONFIG_FILE -PathType Leaf)) {
        error-msg "配置文件不存在: $($script:CONFIG_FILE)"
        detail '请先运行: .\deploy.ps1'
        exit 1
    }
}

function config-wizard {
    step '配置向导'
    Write-Host ''

    ensure-config-file-slot

    # API Key
    $defaultKey = generate-key
    ask '设置 API 密钥 (用于客户端认证)' $defaultKey
    $inputKey = (Read-Host).Trim()
    $script:CPA_API_KEY = if ($inputKey) { $inputKey } else { $defaultKey }
    info "API 密钥: $script:CPA_API_KEY"

    # Port
    ask '服务端口' $script:CPA_PORT
    $inputPort = (Read-Host).Trim()
    $script:CPA_PORT = if ($inputPort) { $inputPort } else { $script:CPA_PORT }
    info "服务端口: $script:CPA_PORT"

    # Management panel
    if (confirm-prompt '是否启用管理面板？' 'y') {
        $defaultMgmt = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
        ask '管理面板密码' $defaultMgmt
        $inputMgmt = (Read-Host).Trim()
        $script:CPA_MANAGEMENT_KEY = if ($inputMgmt) { $inputMgmt } else { $defaultMgmt }
        info "管理面板: 启用  密码: $script:CPA_MANAGEMENT_KEY"
    } else {
        $script:CPA_MANAGEMENT_KEY = ''
        info '管理面板: 禁用'
    }

    # Debug mode
    $debugMode = 'false'
    if (confirm-prompt '是否开启调试日志？(首次部署建议开启)' 'y') {
        $debugMode = 'true'
    }

    divider

    # Generate config.yaml
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $configContent = @"
# =============================================================================
#  Antigravity Proxy 配置文件
#  由 deploy.ps1 自动生成于 $timestamp
# =============================================================================

host: ""
port: 8317

auth-dir: "/root/.cli-proxy-api"

api-keys:
  - "$script:CPA_API_KEY"

debug: $debugMode

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
  secret-key: "$script:CPA_MANAGEMENT_KEY"
  disable-control-panel: false
"@
    $configContent | Set-Content -Path $script:CONFIG_FILE -Encoding UTF8

    info '配置文件已生成: config.yaml'
}

# ========================== 核心操作 ==========================================

function Test-DockerImageExists($image) {
    try {
        docker image inspect $image *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function pull-image {
    step '拉取最新镜像'
    detail $script:DOCKER_IMAGE

    $hasLocalImage = Test-DockerImageExists $script:DOCKER_IMAGE
    if ($hasLocalImage) {
        detail '检测到本地镜像；如果拉取失败，将使用本地缓存继续'
    }

    $pullOutput = @()
    $pullExitCode = 1
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $pullOutput = docker pull $script:DOCKER_IMAGE 2>&1
        $pullExitCode = $LASTEXITCODE
    } catch {
        $pullOutput = @($_.Exception.Message)
    } finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }

    if ($pullExitCode -eq 0) {
        info '镜像已就绪'
    } elseif ($hasLocalImage -or (Test-DockerImageExists $script:DOCKER_IMAGE)) {
        warn '镜像拉取失败，使用本地缓存镜像继续'
        $pullOutput |
            Where-Object { $_ } |
            Select-Object -Last 3 |
            ForEach-Object { detail $_ }
    } else {
        error-msg '镜像拉取失败，请检查网络'
        $pullOutput |
            Where-Object { $_ } |
            Select-Object -Last 3 |
            ForEach-Object { detail $_ }
        exit 1
    }
}

function do-login($provider = 'antigravity') {
    $loginFlag = ''
    $authPattern = ''

    step "OAuth 登录 — $provider"

    switch ($provider) {
        'antigravity' { $loginFlag = '-antigravity-login'; $authPattern = 'antigravity*' }
        'claude'      { $loginFlag = '-claude-login';      $authPattern = 'claude*' }
        'gemini'      { $loginFlag = '-login';             $authPattern = '*.json' }
        'codex'       { $loginFlag = '-codex-login';       $authPattern = 'codex*' }
        default       { error-msg "不支持的 Provider: $provider"; exit 1 }
    }

    # 检查已有凭证
    $volumeExists = $false
    try { $null = docker volume inspect $script:AUTH_VOLUME 2>$null; if ($LASTEXITCODE -eq 0) { $volumeExists = $true } } catch { }

    if ($volumeExists) {
        $authCheck = docker run --rm -v "$($script:AUTH_VOLUME):/auth" alpine sh -c "find /auth -name '$authPattern' 2>/dev/null | head -1" 2>$null
        if ($authCheck) {
            warn "检测到已有 $provider 凭证"
            if (-not (confirm-prompt '是否重新登录覆盖？' 'n')) {
                info '保留已有凭证，跳过登录'
                return
            }
        }
    }

    Write-Host ''
    Write-Host '     即将生成 OAuth 登录链接' -ForegroundColor Yellow
    Write-Host '     请复制终端中的链接到浏览器完成授权，然后回到终端' -ForegroundColor Yellow
    Write-Host ''

    if (-not (confirm-prompt '准备好了吗？' 'y')) {
        warn '跳过登录（稍后可通过 .\deploy.ps1 login 补充登录）'
        return
    }

    $loginOk = $false
    try {
        docker run --rm -it `
            -p "$($script:OAUTH_PORT):$($script:OAUTH_PORT)" `
            -v "$($script:CONFIG_FILE):/CLIProxyAPI/config.yaml:ro" `
            -v "$($script:AUTH_VOLUME):/root/.cli-proxy-api" `
            $script:DOCKER_IMAGE `
            ./CLIProxyAPI `
            -config /CLIProxyAPI/config.yaml `
            $loginFlag `
            "-oauth-callback-port" "$($script:OAUTH_PORT)" `
            -no-browser
        if ($LASTEXITCODE -eq 0) { $loginOk = $true }
    } catch { }

    if (-not $loginOk) {
        warn '登录命令未完成（可稍后重试: .\deploy.ps1 login）'
        return
    }

    $savedAuth = docker run --rm -v "$($script:AUTH_VOLUME):/auth" alpine sh -c "find /auth -name '$authPattern' 2>/dev/null | head -1" 2>$null
    if (-not $savedAuth) {
        warn "未检测到 $provider 凭证文件，请确认浏览器授权是否完成"
        return
    }

    info "$provider 登录成功"
}

function start-service {
    step '启动代理服务'

    require-config-file

    Push-Location $script:SCRIPT_DIR

    try {
        # 停止已有容器
        $existingContainers = docker ps -a --format '{{.Names}}' 2>$null
        if ($existingContainers -and ($existingContainers -match "^$script:CONTAINER_NAME$")) {
            detail '停止旧容器...'
            $env:CPA_PORT = $script:CPA_PORT
            try { Invoke-Compose -f $script:COMPOSE_FILE down 2>$null } catch { }
            $stillExists = docker ps -a --format '{{.Names}}' 2>$null
            if ($stillExists -and ($stillExists -match "^$script:CONTAINER_NAME$")) {
                detail '清理旧项目遗留容器...'
                docker rm -f $script:CONTAINER_NAME 2>$null | Out-Null
            }
        }

        # 启动
        $env:CPA_PORT = $script:CPA_PORT
        $upResult = Invoke-Compose -f $script:COMPOSE_FILE up -d 2>&1 | Select-Object -Last 1

        # 等待就绪
        Write-Host '     等待服务就绪 ' -NoNewline
        $ready = $false
        for ($i = 0; $i -lt 20; $i++) {
            try {
                $apiKey = if ($script:CPA_API_KEY) { $script:CPA_API_KEY } else { 'dummy' }
                $null = Invoke-WebRequest -Uri "http://127.0.0.1:$($script:CPA_PORT)/v1/models" `
                    -Headers @{ Authorization = "Bearer $apiKey" } `
                    -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                $ready = $true
                break
            } catch { }
            Write-Host '·' -NoNewline
            Start-Sleep -Seconds 1
        }
        Write-Host ''

        if ($ready) {
            info '服务已启动并响应正常'
        } else {
            $runningContainers = docker ps --format '{{.Names}}' 2>$null
            if ($runningContainers -and ($runningContainers -match "^$script:CONTAINER_NAME$")) {
                info '容器已运行（API 响应可能需等待 OAuth 凭证生效）'
            } else {
                error-msg '启动失败，查看日志:'
                $env:CPA_PORT = $script:CPA_PORT
                Invoke-Compose -f $script:COMPOSE_FILE logs --tail 30
                exit 1
            }
        }
    } finally {
        Pop-Location
    }
}

# ========================== 显示最终信息 ======================================

function show-result {
    Write-Host ''
    Write-Host '  🎉 部署完成！' -ForegroundColor Green
    Write-Host ''
    divider
    Write-Host ''
    Write-Host '  服务信息'
    Write-Host "  代理地址  http://127.0.0.1:$($script:CPA_PORT)" -ForegroundColor Green
    Write-Host "  API 密钥  $script:CPA_API_KEY" -ForegroundColor Green
    if ($script:CPA_MANAGEMENT_KEY) {
        Write-Host "  管理面板  http://127.0.0.1:$($script:CPA_PORT)/panel" -ForegroundColor Green
        Write-Host "  面板密码  $script:CPA_MANAGEMENT_KEY" -ForegroundColor Green
    }
    Write-Host ''
    divider
    Write-Host ''
    Write-Host '  Claude Code for VS Code 配置'
    Write-Host ''
    Write-Host '  在 VS Code settings.json 中添加:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  // settings.json'
    Write-Host '  {' -ForegroundColor Green
    Write-Host '    "claude-code.env": {' -ForegroundColor Green
    Write-Host "    `"ANTHROPIC_BASE_URL`": `"http://127.0.0.1:$($script:CPA_PORT)`"," -ForegroundColor Green
    Write-Host "    `"ANTHROPIC_AUTH_TOKEN`": `"$script:CPA_API_KEY`"" -ForegroundColor Green
    Write-Host '  }' -ForegroundColor Green
    Write-Host '}' -ForegroundColor Green
    Write-Host ''
    Write-Host '  或在 PowerShell 配置文件中添加:' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:'"$($script:CPA_PORT)"'"' -ForegroundColor Green
    Write-Host '$env:ANTHROPIC_AUTH_TOKEN = "'"$script:CPA_API_KEY"'"' -ForegroundColor Green
    Write-Host ''
    divider
    Write-Host ''
    Write-Host '  常用命令'
    Write-Host '  .\deploy.ps1 status     查看服务状态' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 logs       查看实时日志' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 restart    重启服务' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 stop       停止服务' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 update     更新到最新版本' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 login      重新 OAuth 登录' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 uninstall  完全卸载' -ForegroundColor Cyan
    Write-Host ''
}

# ========================== 子命令实现 ========================================

function cmd-deploy {
    banner
    check-prereqs
    config-wizard
    pull-image

    Write-Host ''
    Write-Host '  选择要登录的 Provider' -ForegroundColor White
    Write-Host '  (CLIProxyAPI 支持多种 Provider，可后续追加)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  1) Antigravity    (Google DeepMind)' -ForegroundColor Cyan
    Write-Host '  2) Claude Code    (Anthropic)' -ForegroundColor Cyan
    Write-Host '  3) Gemini CLI     (Google)' -ForegroundColor Cyan
    Write-Host '  4) Codex          (OpenAI)' -ForegroundColor Cyan
    Write-Host '  5) 跳过登录      (稍后手动登录)' -ForegroundColor Cyan
    Write-Host ''
    ask '选择' '1'
    $providerChoice = (Read-Host).Trim()
    if (-not $providerChoice) { $providerChoice = '1' }

    switch ($providerChoice) {
        '1' { do-login 'antigravity' }
        '2' { do-login 'claude' }
        '3' { do-login 'gemini' }
        '4' { do-login 'codex' }
        '5' { warn '跳过登录（稍后通过 .\deploy.ps1 login 补充）' }
        default { do-login 'antigravity' }
    }

    start-service
    show-result
}

function cmd-login {
    banner
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }

    Write-Host ''
    Write-Host '  选择要登录的 Provider' -ForegroundColor White
    Write-Host ''
    Write-Host '  1) Antigravity    (Google DeepMind)' -ForegroundColor Cyan
    Write-Host '  2) Claude Code    (Anthropic)' -ForegroundColor Cyan
    Write-Host '  3) Gemini CLI     (Google)' -ForegroundColor Cyan
    Write-Host '  4) Codex          (OpenAI)' -ForegroundColor Cyan
    Write-Host ''
    ask '选择' '1'
    $choice = (Read-Host).Trim()
    if (-not $choice) { $choice = '1' }

    switch ($choice) {
        '1' { do-login 'antigravity' }
        '2' { do-login 'claude' }
        '3' { do-login 'gemini' }
        '4' { do-login 'codex' }
        default { do-login 'antigravity' }
    }

    # 重启服务（如果正在运行）
    $runningContainers = docker ps --format '{{.Names}}' 2>$null
    if ($runningContainers -and ($runningContainers -match "^$script:CONTAINER_NAME$")) {
        if (confirm-prompt '服务正在运行，是否立即重启以应用新凭证？' 'y') {
            Push-Location $script:SCRIPT_DIR
            try {
                $env:CPA_PORT = $script:CPA_PORT
                Invoke-Compose -f $script:COMPOSE_FILE restart 2>&1 | Select-Object -Last 1
                info '服务已重启'
            } finally { Pop-Location }
        }
    }
}

function cmd-start {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }

    # 尝试从现有 config 读取 API key
    if ((Test-Path $script:CONFIG_FILE -PathType Leaf) -and -not $script:CPA_API_KEY) {
        $lines = Get-Content $script:CONFIG_FILE
        foreach ($line in $lines) {
            if ($line -match '^\s*-\s*"(sk-[^"]+)"') {
                $script:CPA_API_KEY = $Matches[1]
                break
            }
        }
    }

    start-service

    Write-Host ''
    info "代理地址: http://127.0.0.1:$($script:CPA_PORT)"
}

function cmd-stop {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }
    Push-Location $script:SCRIPT_DIR
    try {
        $env:CPA_PORT = $script:CPA_PORT
        Invoke-Compose -f $script:COMPOSE_FILE down 2>&1 | Select-Object -Last 1
        info '服务已停止'
    } finally { Pop-Location }
}

function cmd-restart {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }
    Push-Location $script:SCRIPT_DIR
    try {
        $env:CPA_PORT = $script:CPA_PORT
        Invoke-Compose -f $script:COMPOSE_FILE restart 2>&1 | Select-Object -Last 1
        info '服务已重启'
    } finally { Pop-Location }
}

function cmd-status {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }

    Write-Host ''
    $runningContainers = docker ps --format '{{.Names}}' 2>$null
    if ($runningContainers -and ($runningContainers -match "^$script:CONTAINER_NAME$")) {
        info '服务状态: 运行中'
        Write-Host ''
        docker ps --filter "name=$script:CONTAINER_NAME" --format '     容器: {{.Names}}  |  状态: {{.Status}}  |  端口: {{.Ports}}'
        Write-Host ''

        # 尝试从现有 config 读取 API key
        if ((Test-Path $script:CONFIG_FILE -PathType Leaf) -and -not $script:CPA_API_KEY) {
            $lines = Get-Content $script:CONFIG_FILE
            foreach ($line in $lines) {
                if ($line -match '^\s*-\s*"(sk-[^"]+)"') {
                    $script:CPA_API_KEY = $Matches[1]
                    break
                }
            }
            if (-not $script:CPA_API_KEY) { $script:CPA_API_KEY = 'dummy' }
        }

        # 从容器端口映射获取实际端口
        $mappedPort = docker port $script:CONTAINER_NAME 8317/tcp 2>$null
        if ($mappedPort) {
            $script:CPA_PORT = ($mappedPort -split ':')[-1]
        }

        Write-Host '     API 测试: ' -NoNewline
        try {
            $apiKey = if ($script:CPA_API_KEY) { $script:CPA_API_KEY } else { 'dummy' }
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$($script:CPA_PORT)/v1/models" `
                -Headers @{ Authorization = "Bearer $apiKey" } `
                -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $httpCode = [int]$resp.StatusCode
        } catch {
            if ($_.Exception.Response) {
                $httpCode = [int]$_.Exception.Response.StatusCode
            } else {
                $httpCode = 0
            }
        }

        if ($httpCode -eq 200) {
            Write-Host "正常 ($httpCode)" -ForegroundColor Green
        } elseif ($httpCode -eq 401) {
            Write-Host "认证失败 ($httpCode) — 请检查 API Key" -ForegroundColor Yellow
        } elseif ($httpCode -eq 0) {
            Write-Host '无响应 — 服务可能仍在初始化' -ForegroundColor Yellow
        } else {
            Write-Host "异常 ($httpCode)" -ForegroundColor Yellow
        }

        # 凭证检查
        Write-Host ''
        Write-Host '     已登录凭证: ' -NoNewline
        $credInfo = docker run --rm -v "$($script:AUTH_VOLUME):/auth" alpine sh -c "ls /auth/ 2>/dev/null | grep -Ev '^(config|logs)$' | tr '\n' ' '" 2>$null
        if ($credInfo) {
            Write-Host $credInfo -ForegroundColor DarkGray
        } else {
            Write-Host '无' -ForegroundColor DarkGray
        }
    } else {
        warn '服务未运行'
        detail '使用 .\deploy.ps1 start 启动'
    }
    Write-Host ''
}

function cmd-logs {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }
    Push-Location $script:SCRIPT_DIR
    try {
        $env:CPA_PORT = $script:CPA_PORT
        Invoke-Compose -f $script:COMPOSE_FILE logs -f --tail 100
    } finally { Pop-Location }
}

function cmd-update {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }
    require-config-file

    pull-image
    Push-Location $script:SCRIPT_DIR
    try {
        $env:CPA_PORT = $script:CPA_PORT
        Invoke-Compose -f $script:COMPOSE_FILE up -d 2>&1 | Select-Object -Last 1
        info '已更新到最新版本'
    } finally { Pop-Location }
}

function cmd-uninstall {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }

    Write-Host ''
    warn '即将完全卸载 Antigravity Proxy'
    Write-Host ''

    if (-not (confirm-prompt '确认卸载？(这将删除容器、凭证卷和配置文件)' 'n')) {
        info '取消卸载'
        return
    }

    Push-Location $script:SCRIPT_DIR
    try {
        $env:CPA_PORT = $script:CPA_PORT
        try { Invoke-Compose -f $script:COMPOSE_FILE down -v 2>$null } catch { }
        try { docker volume rm $script:AUTH_VOLUME 2>$null } catch { }
    } finally { Pop-Location }

    if (confirm-prompt '是否删除配置文件 (config.yaml)？' 'n') {
        if (Test-Path $script:CONFIG_FILE -PathType Container) {
            $items = Get-ChildItem $script:CONFIG_FILE -ErrorAction SilentlyContinue
            if ($items -and $items.Count -gt 0) {
                warn 'config.yaml 是非空目录，未自动删除'
                detail "路径: $($script:CONFIG_FILE)"
            } else {
                Remove-Item $script:CONFIG_FILE -Force
                info '配置目录已删除'
            }
        } else {
            Remove-Item $script:CONFIG_FILE -Force -ErrorAction SilentlyContinue
            info '配置文件已删除'
        }
    }

    info '卸载完成'
}

# ========================== 帮助信息 ==========================================

function show-help {
    Write-Host ''
    Write-Host "  Antigravity Proxy v$script:VERSION"
    Write-Host '  一键部署 CLIProxyAPI 反代 Antigravity' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  用法:'
    Write-Host '    .\deploy.ps1 [命令]' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  命令:'
    Write-Host '    (无参数)     交互式完整部署 (推荐首次使用)' -ForegroundColor Cyan
    Write-Host '    login        OAuth 登录 Provider' -ForegroundColor Cyan
    Write-Host '    start        启动服务' -ForegroundColor Cyan
    Write-Host '    stop         停止服务' -ForegroundColor Cyan
    Write-Host '    restart      重启服务' -ForegroundColor Cyan
    Write-Host '    status       查看服务状态' -ForegroundColor Cyan
    Write-Host '    logs         查看实时日志' -ForegroundColor Cyan
    Write-Host '    update       更新到最新版本' -ForegroundColor Cyan
    Write-Host '    uninstall    完全卸载' -ForegroundColor Cyan
    Write-Host '    help         显示此帮助' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  环境变量:'
    Write-Host '    CPA_PORT     服务端口 (默认: 8317)' -ForegroundColor Cyan
    Write-Host '    CPA_API_KEY  API 密钥' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  示例:'
    Write-Host '    # 完整部署' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1'
    Write-Host ''
    Write-Host '    # 使用自定义端口' -ForegroundColor DarkGray
    Write-Host '    $env:CPA_PORT=9000; .\deploy.ps1 start'
    Write-Host ''
}

# ========================== 入口 ==============================================

function main {
    # 加载 .env
    $envFile = Join-Path $script:SCRIPT_DIR '.env'
    if (Test-Path $envFile -PathType Leaf) {
        Get-Content $envFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#')) {
                $parts = $line -split '=', 2
                if ($parts.Length -eq 2) {
                    $key = $parts[0].Trim()
                    $val = $parts[1].Trim()
                    Set-Item -Path "env:$key" -Value $val
                    # Sync to script vars
                    switch ($key) {
                        'CPA_PORT'           { $script:CPA_PORT = $val }
                        'CPA_API_KEY'        { $script:CPA_API_KEY = $val }
                        'CPA_MANAGEMENT_KEY' { $script:CPA_MANAGEMENT_KEY = $val }
                    }
                }
            }
        }
    }

    $command = if ($args.Count -gt 0) { $args[0] } else { '' }

    switch ($command) {
        'login'     { cmd-login @args }
        'start'     { cmd-start @args }
        'stop'      { cmd-stop @args }
        'restart'   { cmd-restart @args }
        'status'    { cmd-status @args }
        'logs'      { cmd-logs @args }
        'update'    { cmd-update @args }
        'uninstall' { cmd-uninstall @args }
        'help'      { show-help }
        '--help'    { show-help }
        '-h'        { show-help }
        ''          { cmd-deploy }
        default     { error-msg "未知命令: $command"; show-help; exit 1 }
    }
}

main @args
