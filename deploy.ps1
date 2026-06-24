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
#          .\deploy.ps1 logout   # 退出 Provider 账号
#          .\deploy.ps1 start    # 仅启动服务
#          .\deploy.ps1 stop     # 停止服务
#          .\deploy.ps1 status   # 查看状态
#          .\deploy.ps1 logs     # 实时日志
#          .\deploy.ps1 doctor   # 自检诊断
#          .\deploy.ps1 backup   # 备份配置和凭证
#          .\deploy.ps1 restore <file> # 恢复配置和凭证
#          .\deploy.ps1 check-update # 检查镜像更新
#          .\deploy.ps1 update   # 更新到最新版
#          .\deploy.ps1 uninstall # 完全卸载
#          .\deploy.ps1 setup-claude # 配置 Claude Code
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
$script:CPA_API_KEYS       = @()

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

function ConvertTo-YamlDoubleQuotedValue($value) {
    return $value.Replace('\', '\\').Replace('"', '\"')
}

function Set-ApiKeysFromInput($inputText, $defaultKey) {
    $keys = @()
    if ($inputText) {
        $keys = $inputText -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    }

    if (-not $keys -or $keys.Count -eq 0) {
        $keys = @($defaultKey)
    }

    $script:CPA_API_KEYS = @($keys)
    $script:CPA_API_KEY = $script:CPA_API_KEYS[0]
}

function Get-ConfigApiKeys {
    if (-not (Test-Path $script:CONFIG_FILE -PathType Leaf)) {
        return @()
    }

    $keys = @()
    $inKeys = $false
    foreach ($line in Get-Content $script:CONFIG_FILE) {
        if ($line -match '^api-keys:\s*$') {
            $inKeys = $true
            continue
        }
        if ($inKeys -and $line -match '^\S') {
            break
        }
        if ($inKeys -and $line -match '^\s*-\s*(.+?)\s*(?:#.*)?$') {
            $value = $Matches[1].Trim()
            if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            if ($value) {
                $keys += $value
            }
        }
    }

    return @($keys)
}

function Sync-ApiKeyFromConfig {
    if (-not $script:CPA_API_KEY -and (Test-Path $script:CONFIG_FILE -PathType Leaf)) {
        $keys = @(Get-ConfigApiKeys)
        if ($keys.Count -gt 0) {
            $script:CPA_API_KEY = $keys[0]
        }
    }
}

function Resolve-BackupPath($requestedPath) {
    if (-not $requestedPath) {
        $backupDir = Join-Path $script:SCRIPT_DIR 'backups'
        return (Join-Path $backupDir ("antigravity-proxy-backup-{0}.tgz" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
    }

    if ([System.IO.Path]::IsPathRooted($requestedPath)) {
        return $requestedPath
    }

    return (Join-Path $script:SCRIPT_DIR $requestedPath)
}

function Get-LocalImageDigest {
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $repoDigest = docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' $script:DOCKER_IMAGE 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $repoDigest) { return '' }
        return (($repoDigest | Select-Object -First 1) -split '@')[-1]
    } catch {
        return ''
    } finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
}

function Get-RemoteImageDigest {
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $output = docker manifest inspect --verbose $script:DOCKER_IMAGE 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) { return '' }
        foreach ($line in $output) {
            if ($line -match '"digest"\s*:\s*"(sha256:[^"]+)"') {
                return $Matches[1]
            }
        }
        return ''
    } catch {
        return ''
    } finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
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
    ask '设置 API 密钥（多个用英文逗号分隔，回车=随机生成）' $defaultKey
    $inputKey = (Read-Host).Trim()
    Set-ApiKeysFromInput $inputKey $defaultKey
    if ($script:CPA_API_KEYS.Count -eq 1) {
        info "API 密钥: $script:CPA_API_KEY"
    } else {
        info "API 密钥: 共 $($script:CPA_API_KEYS.Count) 个"
    }

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
    $apiKeysYaml = ($script:CPA_API_KEYS | ForEach-Object {
        '  - "' + (ConvertTo-YamlDoubleQuotedValue $_) + '"'
    }) -join [Environment]::NewLine
    $configContent = @"
# =============================================================================
#  Antigravity Proxy 配置文件
#  由 deploy.ps1 自动生成于 $timestamp
# =============================================================================

host: ""
port: 8317

auth-dir: "/root/.cli-proxy-api"

api-keys:
$apiKeysYaml

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
    $oauthPort = $script:OAUTH_PORT

    step "OAuth 登录 — $provider"

    switch ($provider) {
        'antigravity' { $loginFlag = '-antigravity-login'; $authPattern = 'antigravity*' }
        'claude'      { $loginFlag = '-claude-login';      $authPattern = 'claude*' }
        'gemini'      { $loginFlag = '-login';             $authPattern = '*.json' }
        'codex'       { $loginFlag = '-codex-login';       $authPattern = 'codex*'; $oauthPort = 1455 }
        default       { error-msg "不支持的 Provider: $provider"; exit 1 }
    }

    require-config-file

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
    Write-Host "     本次 OAuth 回调端口: $oauthPort" -ForegroundColor Yellow
    Write-Host '     请复制终端中的链接到浏览器完成授权，然后回到终端' -ForegroundColor Yellow
    Write-Host ''

    if (-not (confirm-prompt '准备好了吗？' 'y')) {
        warn '跳过登录（稍后可通过 .\deploy.ps1 login 补充登录）'
        return
    }

    $loginOk = $false
    try {
        docker run --rm -it `
            -p "${oauthPort}:${oauthPort}" `
            -v "$($script:CONFIG_FILE):/CLIProxyAPI/config.yaml" `
            -v "$($script:AUTH_VOLUME):/root/.cli-proxy-api" `
            $script:DOCKER_IMAGE `
            ./CLIProxyAPI `
            -config /CLIProxyAPI/config.yaml `
            $loginFlag `
            "-oauth-callback-port" "$oauthPort" `
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

function do-logout($provider) {
    $authPattern = ''
    $displayName = ''

    switch ($provider) {
        'antigravity' { $authPattern = 'antigravity*'; $displayName = 'Antigravity' }
        'claude'      { $authPattern = 'claude*'; $displayName = 'Claude Code' }
        'gemini'      { $authPattern = '*.json'; $displayName = 'Gemini CLI' }
        'codex'       { $authPattern = 'codex*'; $displayName = 'Codex' }
        'all'         { $authPattern = ''; $displayName = '所有 Provider' }
        default       { error-msg "不支持的 Provider: $provider"; exit 1 }
    }

    # 检查凭证卷是否存在
    $volumeExists = $false
    try { $null = docker volume inspect $script:AUTH_VOLUME 2>$null; if ($LASTEXITCODE -eq 0) { $volumeExists = $true } } catch { }
    if (-not $volumeExists) {
        warn '未找到凭证存储卷，没有需要退出的账号'
        return
    }

    # 列出匹配的凭证文件
    $credFiles = ''
    if ($provider -eq 'all') {
        $credFiles = docker run --rm -v "$($script:AUTH_VOLUME):/auth" alpine sh -c "find /auth -maxdepth 1 -type f 2>/dev/null | grep -Ev '/(config|logs)$' | sed 's|/auth/||'" 2>$null
    } else {
        $credFiles = docker run --rm -v "$($script:AUTH_VOLUME):/auth" alpine sh -c "find /auth -maxdepth 1 -name '$authPattern' -type f 2>/dev/null | sed 's|/auth/||'" 2>$null
    }

    if (-not $credFiles) {
        warn "未检测到 $displayName 的凭证文件"
        return
    }

    Write-Host ''
    Write-Host "     将要删除以下 $displayName 凭证文件:" -ForegroundColor Yellow
    $credFiles -split "`n" | Where-Object { $_.Trim() } | ForEach-Object {
        Write-Host "       • $_" -ForegroundColor DarkGray
    }
    Write-Host ''

    if (-not (confirm-prompt "确认退出 ${displayName} 账号？" 'n')) {
        info '取消操作'
        return
    }

    # 删除凭证文件
    if ($provider -eq 'all') {
        docker run --rm -v "$($script:AUTH_VOLUME):/auth" alpine sh -c "find /auth -maxdepth 1 -type f | grep -Ev '/(config|logs)$' | xargs rm -f" 2>$null
    } else {
        docker run --rm -v "$($script:AUTH_VOLUME):/auth" alpine sh -c "find /auth -maxdepth 1 -name '$authPattern' -type f -exec rm -f {} +" 2>$null
    }

    info "$displayName 凭证已删除"
}

function start-service {
    step '启动代理服务'

    require-config-file
    Sync-ApiKeyFromConfig

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
    Sync-ApiKeyFromConfig
    $apiKeys = @(Get-ConfigApiKeys)

    Write-Host ''
    Write-Host '  🎉 部署完成！' -ForegroundColor Green
    Write-Host ''
    divider
    Write-Host ''
    Write-Host '  服务信息'
    Write-Host "  代理地址  http://127.0.0.1:$($script:CPA_PORT)" -ForegroundColor Green
    if ($apiKeys.Count -gt 1) {
        Write-Host "  API 密钥  $script:CPA_API_KEY (共 $($apiKeys.Count) 个)" -ForegroundColor Green
    } else {
        Write-Host "  API 密钥  $script:CPA_API_KEY" -ForegroundColor Green
    }
    if ($script:CPA_MANAGEMENT_KEY) {
        Write-Host "  管理面板  http://127.0.0.1:$($script:CPA_PORT)/management.html" -ForegroundColor Green
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
    Write-Host '  .\deploy.ps1 doctor     自检 Docker/配置/凭证/API' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 backup     备份配置和 OAuth 凭证' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 check-update 检查镜像更新' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 update     更新到最新版本' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 login      重新 OAuth 登录' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 logout     退出 Provider 账号' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 setup-claude 自动配置 Claude Code' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 uninstall  完全卸载' -ForegroundColor Cyan
    Write-Host ''
}

# ========================== 子命令实现 ========================================

function cmd-deploy {
    banner
    check-prereqs

    if (Test-Path $script:CONFIG_FILE -PathType Leaf) {
        step '检测到已有 config.yaml'
        Write-Host '  1) 重新配置（覆盖现有 config 与全部 key）' -ForegroundColor Cyan
        Write-Host '  2) 保留并仅启动' -ForegroundColor Cyan
        Write-Host ''
        ask '选择' '2'
        $configChoice = (Read-Host).Trim()
        if (-not $configChoice) { $configChoice = '2' }

        if ($configChoice -ne '1') {
            info '保留现有配置，仅启动服务'
            start-service
            show-result
            return
        }

        warn '将覆盖现有 config.yaml 与全部 API key'
    }

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
    require-config-file

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

function cmd-logout {
    banner
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }

    # 检查凭证卷
    $volumeExists = $false
    try { $null = docker volume inspect $script:AUTH_VOLUME 2>$null; if ($LASTEXITCODE -eq 0) { $volumeExists = $true } } catch { }
    if (-not $volumeExists) {
        warn '未找到凭证存储卷，没有已登录的账号'
        return
    }

    # 显示当前凭证状态
    step '当前已登录凭证'
    $credInfo = docker run --rm -v "$($script:AUTH_VOLUME):/auth" alpine sh -c "ls /auth/ 2>/dev/null | grep -Ev '^(config|logs)$' | tr '\n' ' '" 2>$null
    if (-not $credInfo) {
        warn '当前没有已登录的账号'
        return
    }
    Write-Host "     $credInfo" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '  选择要退出的 Provider' -ForegroundColor White
    Write-Host ''
    Write-Host '  1) Antigravity    (Google DeepMind)' -ForegroundColor Cyan
    Write-Host '  2) Claude Code    (Anthropic)' -ForegroundColor Cyan
    Write-Host '  3) Gemini CLI     (Google)' -ForegroundColor Cyan
    Write-Host '  4) Codex          (OpenAI)' -ForegroundColor Cyan
    Write-Host '  5) 全部退出      (清除所有凭证)' -ForegroundColor Cyan
    Write-Host ''
    ask '选择' '1'
    $choice = (Read-Host).Trim()
    if (-not $choice) { $choice = '1' }

    switch ($choice) {
        '1' { do-logout 'antigravity' }
        '2' { do-logout 'claude' }
        '3' { do-logout 'gemini' }
        '4' { do-logout 'codex' }
        '5' { do-logout 'all' }
        default { do-logout 'antigravity' }
    }

    # 重启服务（如果正在运行）
    $runningContainers = docker ps --format '{{.Names}}' 2>$null
    if ($runningContainers -and ($runningContainers -match "^$script:CONTAINER_NAME$")) {
        if (confirm-prompt '服务正在运行，是否立即重启以应用变更？' 'y') {
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
    Sync-ApiKeyFromConfig

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
        Sync-ApiKeyFromConfig
        if (-not $script:CPA_API_KEY) { $script:CPA_API_KEY = 'dummy' }

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

function cmd-doctor {
    banner
    step 'Doctor 自检'

    $failures = 0
    $warnings = 0
    $dockerOk = $false
    $composeOk = $false
    $containerRunning = $false
    $mappedPort = $script:CPA_PORT

    try {
        $null = Get-Command docker -ErrorAction Stop
        info 'Docker CLI 已安装'
    } catch {
        error-msg '未检测到 Docker CLI'
        $failures++
    }

    try {
        $null = docker info 2>$null
        if ($LASTEXITCODE -eq 0) {
            $dockerOk = $true
            info 'Docker 守护进程运行中'
        } else {
            throw 'docker info failed'
        }
    } catch {
        error-msg 'Docker 守护进程不可用'
        detail '请启动 Docker Desktop 后重试'
        $failures++
    }

    $script:COMPOSE_CMD = detect-compose
    if ($script:COMPOSE_CMD) {
        $composeOk = $true
        info "Docker Compose 可用 ($script:COMPOSE_CMD)"
    } else {
        error-msg 'Docker Compose 不可用'
        $failures++
    }

    if (Test-Path $script:CONFIG_FILE -PathType Container) {
        error-msg 'config.yaml 当前是目录，不是文件'
        detail '请删除空目录后重新运行部署'
        $failures++
    } elseif (Test-Path $script:CONFIG_FILE -PathType Leaf) {
        $keyCount = @(Get-ConfigApiKeys).Count
        if ($keyCount -gt 0) {
            info "config.yaml 存在，API key 数量: $keyCount"
        } else {
            warn 'config.yaml 存在，但未读取到 api-keys'
            $warnings++
        }
    } else {
        error-msg 'config.yaml 不存在'
        detail '请先运行: .\deploy.ps1'
        $failures++
    }

    if ($composeOk -and (Test-Path $script:CONFIG_FILE -PathType Leaf)) {
        Push-Location $script:SCRIPT_DIR
        try {
            $env:CPA_PORT = $script:CPA_PORT
            Invoke-Compose -f $script:COMPOSE_FILE config --quiet
            if ($LASTEXITCODE -eq 0) {
                info 'docker-compose.yml 配置有效'
            } else {
                error-msg 'docker-compose.yml 配置检查失败'
                $failures++
            }
        } catch {
            error-msg 'docker-compose.yml 配置检查失败'
            $failures++
        } finally {
            Pop-Location
        }
    }

    if ($dockerOk) {
        $runningContainers = docker ps --format '{{.Names}}' 2>$null
        if ($runningContainers -and ($runningContainers -match "^$script:CONTAINER_NAME$")) {
            $containerRunning = $true
            info "容器正在运行: $script:CONTAINER_NAME"
            $portOutput = docker port $script:CONTAINER_NAME 8317/tcp 2>$null | Select-Object -First 1
            if ($portOutput) {
                $mappedPort = ($portOutput -split ':')[-1]
                info "端口映射正常: 127.0.0.1:$mappedPort"
            } else {
                warn "未读取到容器端口映射，使用配置端口 $($script:CPA_PORT) 测试"
                $warnings++
            }
        } else {
            warn '容器未运行'
            detail '可运行: .\deploy.ps1 start'
            $warnings++
        }

        $volumeExists = $false
        try { $null = docker volume inspect $script:AUTH_VOLUME 2>$null; if ($LASTEXITCODE -eq 0) { $volumeExists = $true } } catch { }
        if ($volumeExists) {
            $credCount = docker run --rm -v "$($script:AUTH_VOLUME):/auth:ro" alpine sh -c "find /auth -maxdepth 1 -type f 2>/dev/null | grep -Ev '/(config|logs)$' | wc -l" 2>$null
            $credCount = if ($credCount) { [int]($credCount.ToString().Trim()) } else { 0 }
            if ($credCount -gt 0) {
                info "OAuth 凭证卷存在，凭证文件数: $credCount"
            } else {
                warn 'OAuth 凭证卷存在，但未找到 Provider 凭证'
                detail '可运行: .\deploy.ps1 login'
                $warnings++
            }
        } else {
            warn 'OAuth 凭证卷不存在'
            detail '完成 login 后会自动创建'
            $warnings++
        }
    }

    if ($containerRunning) {
        Sync-ApiKeyFromConfig
        if (-not $script:CPA_API_KEY) {
            error-msg '无法读取 API key，跳过 /v1/models 测试'
            $failures++
        } else {
            $httpCode = 0
            $content = ''
            try {
                $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$mappedPort/v1/models" `
                    -Headers @{ Authorization = "Bearer $($script:CPA_API_KEY)" } `
                    -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                $httpCode = [int]$resp.StatusCode
                $content = $resp.Content
            } catch {
                if ($_.Exception.Response) {
                    $httpCode = [int]$_.Exception.Response.StatusCode
                }
            }

            if ($httpCode -eq 200) {
                if ($content -match '"id"\s*:') {
                    info '/v1/models 返回 200，且模型列表非空'
                } else {
                    warn '/v1/models 返回 200，但模型列表可能为空'
                    detail '通常表示 OAuth 登录未完成或凭证未加载'
                    $warnings++
                }
            } elseif ($httpCode -eq 401) {
                error-msg '/v1/models 认证失败 (401)'
                detail '请检查 config.yaml 中的 API key'
                $failures++
            } elseif ($httpCode -eq 0) {
                warn '/v1/models 无响应'
                $warnings++
            } else {
                warn "/v1/models 返回异常状态: $httpCode"
                $warnings++
            }
        }
    }

    Write-Host ''
    divider
    if ($failures -eq 0) {
        info "Doctor 完成: $warnings 个警告，0 个错误"
    } else {
        error-msg "Doctor 完成: $warnings 个警告，$failures 个错误"
        exit 1
    }
}

function cmd-backup($requestedPath = '') {
    $dest = Resolve-BackupPath $requestedPath

    if ((Test-Path $dest -PathType Leaf) -and -not (confirm-prompt '备份文件已存在，是否覆盖？' 'n')) {
        info '取消备份'
        return
    }

    $parent = Split-Path $dest -Parent
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $hasConfig = Test-Path $script:CONFIG_FILE -PathType Leaf
    $hasAuth = $false
    try {
        $null = docker info 2>$null
        if ($LASTEXITCODE -eq 0) {
            $null = docker volume inspect $script:AUTH_VOLUME 2>$null
            if ($LASTEXITCODE -eq 0) { $hasAuth = $true }
        }
    } catch { }

    if (-not $hasConfig -and -not $hasAuth) {
        error-msg '没有找到 config.yaml 或 OAuth 凭证卷，无法备份'
        exit 1
    }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("antigravity-proxy-backup-{0}" -f [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    try {
        if ($hasConfig) {
            Copy-Item $script:CONFIG_FILE (Join-Path $tmpDir 'config.yaml') -Force
        } else {
            warn '未找到 config.yaml，本次仅备份凭证卷'
        }

        if ($hasAuth) {
            $authDir = Join-Path $tmpDir 'auth'
            New-Item -ItemType Directory -Path $authDir -Force | Out-Null
            docker run --rm `
                -v "$($script:AUTH_VOLUME):/auth:ro" `
                -v "${authDir}:/backup-auth" `
                alpine sh -c 'cp -a /auth/. /backup-auth/ 2>/dev/null || true' | Out-Null
        } else {
            warn '未找到 OAuth 凭证卷，本次仅备份 config.yaml'
        }

        tar -czf $dest -C $tmpDir .
        if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
    } finally {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    info "备份已创建: $dest"
    detail '包含 config.yaml 和 OAuth 凭证卷（如存在）'
}

function cmd-restore($sourceFile = '') {
    if (-not $sourceFile) {
        error-msg '缺少备份文件'
        detail '用法: .\deploy.ps1 restore backups\antigravity-proxy-backup-YYYYmmdd-HHMMSS.tgz'
        exit 1
    }
    if (-not [System.IO.Path]::IsPathRooted($sourceFile)) {
        $sourceFile = Join-Path $script:SCRIPT_DIR $sourceFile
    }
    if (-not (Test-Path $sourceFile -PathType Leaf)) {
        error-msg "备份文件不存在: $sourceFile"
        exit 1
    }

    warn '恢复会覆盖当前 config.yaml 和 OAuth 凭证卷'
    if (-not (confirm-prompt '确认恢复？' 'n')) {
        info '取消恢复'
        return
    }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("antigravity-proxy-restore-{0}" -f [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    try {
        tar -xzf $sourceFile -C $tmpDir
        if ($LASTEXITCODE -ne 0) { throw 'tar failed' }

        $restoredConfig = Join-Path $tmpDir 'config.yaml'
        $restoredAuth = Join-Path $tmpDir 'auth'
        if (-not (Test-Path $restoredConfig -PathType Leaf) -and -not (Test-Path $restoredAuth -PathType Container)) {
            error-msg '备份文件格式不正确'
            exit 1
        }

        $runningContainers = docker ps --format '{{.Names}}' 2>$null
        if ($runningContainers -and ($runningContainers -match "^$script:CONTAINER_NAME$")) {
            if (confirm-prompt '服务正在运行，是否先停止再恢复？' 'y') {
                docker stop $script:CONTAINER_NAME 2>$null | Out-Null
                info '服务已停止'
            } else {
                warn '服务仍在运行，恢复后建议手动重启'
            }
        }

        if (Test-Path $restoredConfig -PathType Leaf) {
            if (Test-Path $script:CONFIG_FILE -PathType Container) {
                $items = Get-ChildItem $script:CONFIG_FILE -ErrorAction SilentlyContinue
                if ($items -and $items.Count -gt 0) {
                    error-msg 'config.yaml 是非空目录，未覆盖'
                    exit 1
                }
                Remove-Item $script:CONFIG_FILE -Force
            }
            Copy-Item $restoredConfig $script:CONFIG_FILE -Force
            info 'config.yaml 已恢复'
        }

        if (Test-Path $restoredAuth -PathType Container) {
            try { $null = docker info 2>$null; if ($LASTEXITCODE -ne 0) { throw 'docker info failed' } }
            catch {
                error-msg 'Docker 不可用，无法恢复 OAuth 凭证卷'
                exit 1
            }
            docker volume create $script:AUTH_VOLUME | Out-Null
            docker run --rm `
                -v "$($script:AUTH_VOLUME):/auth" `
                -v "${restoredAuth}:/restore-auth:ro" `
                alpine sh -c 'rm -rf /auth/* /auth/.[!.]* /auth/..?* 2>/dev/null || true; cp -a /restore-auth/. /auth/ 2>/dev/null || true' | Out-Null
            info 'OAuth 凭证卷已恢复'
        }
    } finally {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    info '恢复完成'
    detail '可运行: .\deploy.ps1 start'
}

function cmd-check-update {
    step '检查镜像更新'
    detail $script:DOCKER_IMAGE

    try { $null = Get-Command docker -ErrorAction Stop }
    catch {
        error-msg '未检测到 Docker CLI'
        exit 1
    }

    $remoteDigest = Get-RemoteImageDigest
    if (-not $remoteDigest) {
        warn '无法获取远端镜像信息（网络或 registry 限制）'
        exit 1
    }

    $localDigest = Get-LocalImageDigest
    if (-not $localDigest) {
        warn '本地尚未找到镜像，请运行 .\deploy.ps1 update'
        detail "远端 digest: $remoteDigest"
        return
    }

    if ($localDigest -eq $remoteDigest) {
        info '当前镜像已是最新'
        detail "digest: $localDigest"
    } else {
        warn '发现新镜像，可运行 .\deploy.ps1 update'
        detail "本地: $localDigest"
        detail "远端: $remoteDigest"
    }
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

# ========================== setup-claude ======================================

function cmd-setup-claude {
    $port = $script:CPA_PORT
    $apiKey = $script:CPA_API_KEY

    if (-not $apiKey -and (Test-Path $script:CONFIG_FILE)) {
        $match = Select-String -Path $script:CONFIG_FILE -Pattern '^\s*-\s*"([^"]+)"' | Select-Object -First 1
        if ($match) { $apiKey = $match.Matches.Groups[1].Value }
    }

    if (-not $apiKey) {
        error-msg '未找到 API Key。请先运行部署或设置 CPA_API_KEY'
        error-msg 'API Key not found. Run deploy first or set CPA_API_KEY'
        exit 1
    }

    $settingsDir = Join-Path $HOME '.claude'
    $settingsFile = Join-Path $settingsDir 'settings.json'
    $baseUrl = "http://127.0.0.1:$port"

    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }

    $settings = @{}
    if (Test-Path $settingsFile) {
        try {
            $settings = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        } catch {
            $settings = @{}
        }
    }

    if (-not $settings.ContainsKey('env')) { $settings['env'] = @{} }
    $settings['env']['ANTHROPIC_BASE_URL'] = $baseUrl
    $settings['env']['ANTHROPIC_AUTH_TOKEN'] = $apiKey

    if (-not $settings.ContainsKey('extraKnownMarketplaces')) { $settings['extraKnownMarketplaces'] = @{} }
    $settings['extraKnownMarketplaces']['ecc'] = @{
        source = @{
            source = 'github'
            repo   = 'affaan-m/everything-claude-code'
        }
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8

    Write-Host ''
    info 'Claude Code 已配置 / Claude Code configured'
    Write-Host ''
    Write-Host "  $settingsFile 已更新:"
    Write-Host ''
    Write-Host "  ANTHROPIC_BASE_URL   $baseUrl" -ForegroundColor Green
    Write-Host "  ANTHROPIC_AUTH_TOKEN  $apiKey" -ForegroundColor Green
    Write-Host '  ECC 插件市场          已启用 / enabled' -ForegroundColor Green
    Write-Host ''
    Write-Host '  现在可以直接运行 claude 命令使用代理' -ForegroundColor DarkGray
    Write-Host '  You can now run "claude" directly with the proxy' -ForegroundColor DarkGray
    Write-Host ''
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
    Write-Host '    logout       退出 Provider 账号' -ForegroundColor Cyan
    Write-Host '    start        启动服务' -ForegroundColor Cyan
    Write-Host '    stop         停止服务' -ForegroundColor Cyan
    Write-Host '    restart      重启服务' -ForegroundColor Cyan
    Write-Host '    status       查看服务状态' -ForegroundColor Cyan
    Write-Host '    logs         查看实时日志' -ForegroundColor Cyan
    Write-Host '    doctor       自检 Docker/配置/凭证/API' -ForegroundColor Cyan
    Write-Host '    backup [文件] 备份配置和 OAuth 凭证' -ForegroundColor Cyan
    Write-Host '    restore <文件> 恢复配置和 OAuth 凭证' -ForegroundColor Cyan
    Write-Host '    check-update  只检查镜像是否有更新' -ForegroundColor Cyan
    Write-Host '    update       更新到最新版本' -ForegroundColor Cyan
    Write-Host '    uninstall    完全卸载' -ForegroundColor Cyan
    Write-Host '    setup-claude 自动配置 Claude Code 环境' -ForegroundColor Cyan
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
    Write-Host '    # 自检并备份' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1 doctor'
    Write-Host '    .\deploy.ps1 backup'
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
        'logout'    { cmd-logout }
        'start'     { cmd-start @args }
        'stop'      { cmd-stop @args }
        'restart'   { cmd-restart @args }
        'status'    { cmd-status @args }
        'logs'      { cmd-logs @args }
        'doctor'    { cmd-doctor }
        'backup'    {
            $backupPath = if ($args.Count -gt 1) { $args[1] } else { '' }
            cmd-backup $backupPath
        }
        'restore'   {
            $restorePath = if ($args.Count -gt 1) { $args[1] } else { '' }
            cmd-restore $restorePath
        }
        'check-update' { cmd-check-update }
        'update'    { cmd-update @args }
        'uninstall' { cmd-uninstall @args }
        'setup-claude' { cmd-setup-claude }
        'help'      { show-help }
        '--help'    { show-help }
        '-h'        { show-help }
        ''          { cmd-deploy }
        default     { error-msg "未知命令: $command"; show-help; exit 1 }
    }
}

# Only run when executed as a script. When dot-sourced, load functions without
# starting the interactive deploy flow so syntax checks can safely import this file.
if ($MyInvocation.InvocationName -ne '.') {
    main @args
}
