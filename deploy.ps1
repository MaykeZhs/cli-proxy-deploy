#!/usr/bin/env pwsh
# =============================================================================
#
#   ╔═══════════════════════════════════════════════════════════════════╗
#   ║   CLI Proxy Manager — One-Click Deployment for CLIProxyAPI      ║
#   ║   部署和管理 CLIProxyAPI，在 Claude Code / Cursor 等工具中使用            ║
#   ╚═══════════════════════════════════════════════════════════════════╝
#
#   用法:  .\deploy.ps1          # 交互式完整部署
#          .\deploy.ps1 login    # 仅 OAuth 登录
#          .\deploy.ps1 logout   # 退出 Provider 账号
#          .\deploy.ps1 start    # 仅启动服务
#          .\deploy.ps1 stop     # 停止服务
#          .\deploy.ps1 status   # 查看状态
#          .\deploy.ps1 logs     # 实时日志
#          .\deploy.ps1 capabilities [--json] # 只读能力检查
#          .\deploy.ps1 doctor   # 自检诊断
#          .\deploy.ps1 backup   # 备份配置和凭证
#          .\deploy.ps1 restore <file> # 恢复配置和凭证
#          .\deploy.ps1 check-update # 检查镜像更新
#          .\deploy.ps1 update   # 更新到最新版
#          .\deploy.ps1 rollback # 回滚到更新前镜像
#          .\deploy.ps1 uninstall # 完全卸载
#          .\deploy.ps1 setup-claude # 配置 Claude Code
#          .\deploy.ps1 sub2api deploy # 一键部署 Sub2API
#          .\deploy.ps1 cursor-bridge start # 启动可选 Cursor Bridge sidecar
#
# =============================================================================

$ErrorActionPreference = 'Stop'

# ========================== 常量 & 默认值 ====================================

$script:VERSION        = '1.0.0'
$script:SCRIPT_DIR     = $PSScriptRoot
$script:DOCKER_IMAGE   = if ($env:CPA_IMAGE) { $env:CPA_IMAGE } else { 'eceasy/cli-proxy-api:latest' }
$script:ROLLBACK_IMAGE = 'eceasy/cli-proxy-api:rollback'
$script:RELEASE_CONTRACT_CPA_VERSION = 'v7.2.111'
$script:RELEASE_CONTRACT_CPA_COMMIT = '4a315136730baa8b3a436d12b74e5a702c70be5c'
$script:RELEASE_CONTRACT_MANAGEMENT_CENTER_VERSION = 'v1.20.4'
$script:RELEASE_CONTRACT_MANAGEMENT_CENTER_COMMIT = '826ea3c0d0bdd6409a0a2703ada90faaf5aede2d'

$script:COMPOSE_PROJECT_NAME = 'cli-proxy-manager'
$env:COMPOSE_PROJECT_NAME    = $script:COMPOSE_PROJECT_NAME
$script:CONTAINER_NAME = 'cli-proxy-manager'
$script:AUTH_VOLUME    = 'cli-proxy-manager-auth'
$script:OAUTH_PORT     = 51121
$script:CONFIG_FILE    = Join-Path $script:SCRIPT_DIR 'config.yaml'
$script:COMPOSE_FILE            = Join-Path $script:SCRIPT_DIR 'docker-compose.yml'
$script:SUB2API_COMPOSE_FILE     = Join-Path $script:SCRIPT_DIR 'docker-compose.sub2api.yml'
$script:SUB2API_ENV_FILE         = Join-Path $script:SCRIPT_DIR 'sub2api.env'
$script:SUB2API_ENV_EXAMPLE_FILE = Join-Path $script:SCRIPT_DIR 'sub2api.env.example'
$script:SUB2API_PROJECT_NAME     = 'sub2api-manager'
$script:SUB2API_CONTAINER_NAME   = 'sub2api-manager'
$script:SUB2API_POSTGRES_CONTAINER_NAME = 'sub2api-manager-postgres'
$script:SUB2API_REDIS_CONTAINER_NAME    = 'sub2api-manager-redis'
$script:CURSOR_BRIDGE_COMPOSE_FILE     = Join-Path $script:SCRIPT_DIR 'docker-compose.cursor-bridge.yml'
$script:CURSOR_BRIDGE_ENV_FILE         = Join-Path $script:SCRIPT_DIR 'cursor-bridge.env'
$script:CURSOR_BRIDGE_ENV_EXAMPLE_FILE = Join-Path $script:SCRIPT_DIR 'cursor-bridge.env.example'
$script:CURSOR_BRIDGE_PROJECT_NAME     = 'cursor-bridge'
$script:CURSOR_BRIDGE_CONTAINER_NAME   = 'cursor-bridge'
$script:CURSOR_BRIDGE_NETWORK          = 'cpa-cursor-bridge'
$script:CURSOR_BRIDGE_SOURCE_REPOSITORY = 'https://github.com/anyrobert/cursor-api-proxy'
$script:CURSOR_BRIDGE_SOURCE_COMMIT    = 'c0ff1f941215027c0a8f658ca5d01f806559208f'
$script:CURSOR_BRIDGE_IMAGE            = 'cursor-api-proxy:poc-c0ff1f941215027c0a8f658ca5d01f806559208f'

# 用户可配置（在 .env 中覆盖）
$script:CPA_PORT           = if ($env:CPA_PORT)           { $env:CPA_PORT }           else { '8317' }
$script:CPA_API_KEY        = if ($env:CPA_API_KEY)        { $env:CPA_API_KEY }        else { '' }
$script:CPA_MANAGEMENT_KEY = if ($env:CPA_MANAGEMENT_KEY) { $env:CPA_MANAGEMENT_KEY } else { '' }
$script:CPA_API_KEYS       = @()
$script:SUB2API_ENV_CREATED = $false
$script:SUB2API_NEW_ADMIN_PASSWORD = ''

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

function Invoke-NativeChecked($file, [string[]]$arguments, $capture = $false) {
    if ($capture) { $output = & $file @arguments 2>&1 } else { & $file @arguments; $output = $null }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "Native command failed ($exitCode): $file $($arguments -join ' ')" }
    return $output
}

function Invoke-Compose {
    $cmdParts = $script:COMPOSE_CMD -split '\s+'
    $allArgs = @()
    if ($cmdParts.Count -gt 1) { $allArgs += $cmdParts[1] }
    $allArgs += $args
    Invoke-NativeChecked $cmdParts[0] $allArgs
}

function Assert-SafeRepoPath($path, $allowMissing = $false) {
    $root = [IO.Path]::GetFullPath($script:SCRIPT_DIR).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($path)
    if (-not ($full -eq $root -or $full.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase))) { throw "路径超出仓库根目录: $path" }
    $relative = $full.Substring($root.Length).TrimStart('\')
    $current = $root
    foreach ($component in ($relative -split '\\')) {
        if (-not $component) { continue }
        $current = Join-Path $current $component
        if (Test-Path $current) {
            $item = Get-Item $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "拒绝 reparse point: $current" }
        }
    }
    if (-not $allowMissing -and -not (Test-Path $full)) { throw "路径不存在: $full" }
}

function Assert-RegularFile($path) {
    Assert-SafeRepoPath $path
    $item = Get-Item $path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "要求普通文件: $path" }
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

# ========================== CPA 只读能力探针 =================================

function Invoke-ReadOnlyNative {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @()
    )

    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $output = @(& $File @Arguments 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = @($output | ForEach-Object { $_.ToString() })
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = 1
            Output = @()
        }
    } finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
}

function ConvertTo-CapabilityBoolean($value) {
    if ($null -eq $value) { return $null }
    switch ($value.ToString().Trim().ToLowerInvariant()) {
        { $_ -in @('true', 'yes', 'on', '1') } { return $true }
        { $_ -in @('false', 'no', 'off', '0') } { return $false }
        default { return $null }
    }
}

function Test-CapabilityLoopback($address) {
    if (-not $address) { return $false }
    $normalized = $address.ToString().Trim().Trim('[', ']')
    return ($normalized -eq 'localhost' -or $normalized -eq '::1' -or
        $normalized -eq '0:0:0:0:0:0:0:1' -or $normalized.StartsWith('127.'))
}

function Get-CapabilityYamlValue($value) {
    if ($null -eq $value) { return '' }
    $result = $value.ToString() -replace '\s+#.*$', ''
    $result = $result.Trim()
    if ($result.Length -ge 2) {
        if (($result.StartsWith('"') -and $result.EndsWith('"')) -or
            ($result.StartsWith("'") -and $result.EndsWith("'"))) {
            $result = $result.Substring(1, $result.Length - 2)
        }
    }
    return $result
}

function Get-RemoteManagementCapability {
    $result = [ordered]@{
        configured = $false
        allow_remote = $null
        control_panel_disabled = $null
        secret_configured = $null
    }
    if (-not (Test-Path $script:CONFIG_FILE -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $inRemote = $false
    foreach ($line in Get-Content $script:CONFIG_FILE) {
        if ($line -match '^remote-management:\s*(?:#.*)?$') {
            $inRemote = $true
            $result.configured = $true
            continue
        }
        if ($inRemote -and $line -match '^\S' -and $line -notmatch '^#') {
            break
        }
        if (-not $inRemote) { continue }

        if ($line -match '^\s+allow-remote:\s*(.*)$') {
            $result.allow_remote = ConvertTo-CapabilityBoolean (Get-CapabilityYamlValue $Matches[1])
        } elseif ($line -match '^\s+disable-control-panel:\s*(.*)$') {
            $result.control_panel_disabled = ConvertTo-CapabilityBoolean (Get-CapabilityYamlValue $Matches[1])
        } elseif ($line -match '^\s+secret-key:\s*(.*)$') {
            $secretValue = Get-CapabilityYamlValue $Matches[1]
            $result.secret_configured = [bool]$secretValue
        }
    }
    return [pscustomobject]$result
}

function Get-RoutingConfigCapability {
    $result = [ordered]@{
        strategy = $null
        session_affinity_enabled = $null
        session_affinity_ttl = $null
    }
    if (-not (Test-Path $script:CONFIG_FILE -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $result.strategy = 'round-robin'
    $result.session_affinity_enabled = $false
    $result.session_affinity_ttl = '1h'

    $inRouting = $false
    foreach ($line in Get-Content $script:CONFIG_FILE) {
        if ($line -match '^routing:\s*(?:#.*)?$') {
            $inRouting = $true
            continue
        }
        if ($inRouting -and $line -match '^\S' -and $line -notmatch '^#') {
            break
        }
        if (-not $inRouting) { continue }

        if ($line -match '^\s+strategy:\s*(.*)$') {
            $strategy = Get-CapabilityYamlValue $Matches[1]
            $result.strategy = if ($strategy -in @('round-robin', 'weighted-round-robin', 'fill-first')) { $strategy } else { $null }
        } elseif ($line -match '^\s+session-affinity:\s*(.*)$') {
            $result.session_affinity_enabled = ConvertTo-CapabilityBoolean (Get-CapabilityYamlValue $Matches[1])
        } elseif ($line -match '^\s+session-affinity-ttl:\s*(.*)$') {
            $ttl = Get-CapabilityYamlValue $Matches[1]
            $result.session_affinity_ttl = if ($ttl -match '^(?:[0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h))+$') { $ttl } else { $null }
        }
    }
    return [pscustomobject]$result
}

function Get-PluginConfigCapability {
    $result = [ordered]@{
        section_present = $false
        configured = $false
        enabled = $null
    }
    if (-not (Test-Path $script:CONFIG_FILE -PathType Leaf)) {
        return [pscustomobject]$result
    }

    $inPlugins = $false
    foreach ($line in Get-Content $script:CONFIG_FILE) {
        if ($line -match '^plugins:\s*(?:#.*)?$') {
            $inPlugins = $true
            $result.section_present = $true
            $result.configured = $true
            continue
        }
        if ($inPlugins -and $line -match '^\S' -and $line -notmatch '^#') {
            break
        }
        if (-not $inPlugins) { continue }
        if ($line -match '^\s+enabled:\s*(.*)$') {
            $result.enabled = ConvertTo-CapabilityBoolean (Get-CapabilityYamlValue $Matches[1])
        }
    }
    return [pscustomobject]$result
}

function Select-CapabilityBinding([string[]]$lines) {
    $selected = $null
    $selectedPriority = 0
    foreach ($rawLine in $lines) {
        $line = $rawLine.ToString().Trim()
        if (-not $line) { continue }
        $address = $null
        $port = $null
        if ($line -match '^\[(.*)\]:(\d+)$') {
            $address = $Matches[1]
            $port = [int]$Matches[2]
        } elseif ($line -match '^(.*):(\d+)$') {
            $address = $Matches[1]
            $port = [int]$Matches[2]
        }
        if (-not $address -or $null -eq $port) { continue }

        if ($address -eq '0.0.0.0') { $priority = 4 }
        elseif ($address -eq '::') { $priority = 3 }
        elseif (Test-CapabilityLoopback $address) { $priority = 1 }
        else { $priority = 2 }

        if ($priority -gt $selectedPriority) {
            $selected = [pscustomobject]@{ Address = $address; Port = $port }
            $selectedPriority = $priority
        }
    }
    return $selected
}

function Get-CapabilityProbeHost($address) {
    if (-not $address -or $address -eq '0.0.0.0') { return '127.0.0.1' }
    $normalized = $address.ToString().Trim().Trim('[', ']')
    if ($normalized -eq '::') { return '[::1]' }
    if ($normalized.Contains(':')) { return "[$normalized]" }
    return $normalized
}

function Get-CapabilityHeaderValue($headers, $name) {
    if ($null -eq $headers) { return $null }
    try {
        $value = $headers[$name]
        if ($value) { return (@($value) | Select-Object -First 1).ToString().Trim() }
    } catch { }
    try {
        $values = @($headers.GetValues($name))
        if ($values.Count -gt 0) { return $values[0].ToString().Trim() }
    } catch { }
    return $null
}

function Invoke-CapabilityWebRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{}
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing `
            -TimeoutSec 5 -ErrorAction Stop
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = $response.Content
            Headers = $response.Headers
        }
    } catch {
        $response = $_.Exception.Response
        $statusCode = $null
        $responseHeaders = $null
        if ($response) {
            try { $statusCode = [int]$response.StatusCode } catch { }
            try { $responseHeaders = $response.Headers } catch { }
        }
        return [pscustomobject]@{
            StatusCode = $statusCode
            Content = ''
            Headers = $responseHeaders
        }
    }
}

function New-ProviderCredentialCapability {
    $providers = [ordered]@{
        antigravity = $null
        claude = $null
        codex = $null
        gemini = $null
        kimi = $null
        xai = $null
        unknown = $null
    }
    return [pscustomobject][ordered]@{
        inspection = $null
        source = $null
        providers = [pscustomobject]$providers
        additional_providers = @()
        total = $null
    }
}

function Get-ProviderCredentialFallbackCapability($containerRunning) {
    $result = New-ProviderCredentialCapability
    if ($containerRunning -ne $true) { return [pscustomobject]$result }
    $providers = [ordered]@{
        antigravity = $null
        claude = $null
        codex = $null
        gemini = $null
        kimi = $null
        xai = $null
        unknown = $null
    }

    $providerScript = 'auth=/root/.cli-proxy-api; [ -d "$auth" ] || exit 2; antigravity=$(find "$auth" -maxdepth 1 -type f \( -name "antigravity.json" -o -name "antigravity-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]"); claude=$(find "$auth" -maxdepth 1 -type f \( -name "claude.json" -o -name "claude-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]"); codex=$(find "$auth" -maxdepth 1 -type f \( -name "codex.json" -o -name "codex-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]"); gemini=$(find "$auth" -maxdepth 1 -type f \( -name "gemini.json" -o -name "gemini-*.json" -o -name "geminicli.json" -o -name "geminicli-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]"); kimi=$(find "$auth" -maxdepth 1 -type f \( -name "kimi.json" -o -name "kimi-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]"); xai=$(find "$auth" -maxdepth 1 -type f \( -name "xai.json" -o -name "xai-*.json" -o -name "x-ai.json" -o -name "x-ai-*.json" \) 2>/dev/null | wc -l | tr -d "[:space:]"); all=$(find "$auth" -maxdepth 1 -type f -name "*.json" 2>/dev/null | wc -l | tr -d "[:space:]"); printf "antigravity=%s\nclaude=%s\ncodex=%s\ngemini=%s\nkimi=%s\nxai=%s\nall=%s\n" "${antigravity:-0}" "${claude:-0}" "${codex:-0}" "${gemini:-0}" "${kimi:-0}" "${xai:-0}" "${all:-0}"'
    $native = Invoke-ReadOnlyNative -File 'docker' -Arguments @('exec', $script:CONTAINER_NAME, 'sh', '-c', $providerScript)
    if ($native.ExitCode -ne 0) { return [pscustomobject]$result }

    $seen = 0
    $knownTotal = 0
    $allCount = $null
    foreach ($line in $native.Output) {
        if ($line -notmatch '^(antigravity|claude|codex|gemini|kimi|xai|all)=(\d+)$') { continue }
        $provider = $Matches[1]
        $count = [int]$Matches[2]
        if ($provider -eq 'all') {
            $allCount = $count
            continue
        }
        $providers[$provider] = $count
        $knownTotal += $count
        $seen++
    }
    if ($seen -eq 6 -and $null -ne $allCount) {
        $providers.unknown = [Math]::Max(0, $allCount - $knownTotal)
        $result.inspection = 'available'
        $result.source = 'filename_fallback'
        $result.providers = [pscustomobject]$providers
        $result.total = $allCount
    }
    return [pscustomobject]$result
}

function ConvertFrom-AuthFilesCapability($content) {
    try {
        $payload = $content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not ($payload.PSObject.Properties.Name -contains 'files')) { return $null }

    $providers = [ordered]@{
        antigravity = 0
        claude = 0
        codex = 0
        gemini = 0
        kimi = 0
        xai = 0
        unknown = 0
    }
    $additional = [ordered]@{}
    $statusSupported = $false
    $prioritySupported = $false
    $weightConfigured = $false
    $files = @($payload.files)
    foreach ($item in $files) {
        if ($null -eq $item) {
            $providers.unknown++
            continue
        }
        $propertyNames = @($item.PSObject.Properties.Name)
        if ($propertyNames -contains 'status' -or $propertyNames -contains 'status_message') { $statusSupported = $true }
        if ($propertyNames -contains 'priority') { $prioritySupported = $true }
        if ($propertyNames -contains 'weight') { $weightConfigured = $true }
        $rawProvider = if ($propertyNames -contains 'type' -and $item.type) { $item.type }
            elseif ($propertyNames -contains 'provider' -and $item.provider) { $item.provider }
            else { $null }
        if (-not ($rawProvider -is [string])) {
            $providers.unknown++
            continue
        }
        $provider = $rawProvider.Trim().ToLowerInvariant()
        switch ($provider) {
            'gemini-cli' { $provider = 'gemini' }
            'geminicli' { $provider = 'gemini' }
            'x-ai' { $provider = 'xai' }
            'x_ai' { $provider = 'xai' }
        }
        if ($providers.Contains($provider) -and $provider -ne 'unknown') {
            $providers[$provider]++
        } elseif ($provider -match '^[a-z][a-z0-9_-]{0,31}$') {
            if (-not $additional.Contains($provider)) { $additional[$provider] = 0 }
            $additional[$provider]++
        } else {
            $providers.unknown++
        }
    }
    $additionalItems = @($additional.Keys | Sort-Object | ForEach-Object {
        [pscustomobject][ordered]@{ type = $_; count = [int]$additional[$_] }
    })
    return [pscustomobject][ordered]@{
        credentials = [pscustomobject][ordered]@{
            inspection = 'available'
            source = 'management_api'
            providers = [pscustomobject]$providers
            additional_providers = $additionalItems
            total = $files.Count
        }
        status_supported = $statusSupported
        priority_supported = $prioritySupported
        priority_configured = $prioritySupported
        weight_configured = $weightConfigured
    }
}

function ConvertFrom-ManagementConfigCapability($content) {
    try {
        $payload = $content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $payload) { return $null }

    $priorityConfigured = $false
    $weightConfigured = $false
    foreach ($section in @(
        'gemini-api-key',
        'interactions-api-key',
        'claude-api-key',
        'vertex-api-key',
        'codex-api-key',
        'xai-api-key'
    )) {
        if ($payload.PSObject.Properties.Name -notcontains $section) { continue }
        foreach ($entry in @($payload.$section)) {
            if ($null -eq $entry) { continue }
            $propertyNames = @($entry.PSObject.Properties.Name)
            if ($propertyNames -contains 'priority') { $priorityConfigured = $true }
            if ($propertyNames -contains 'weight') { $weightConfigured = $true }
        }
    }

    if ($payload.PSObject.Properties.Name -contains 'openai-compatibility') {
        foreach ($provider in @($payload.'openai-compatibility')) {
            if ($null -eq $provider) { continue }
            $providerProperties = @($provider.PSObject.Properties.Name)
            if ($providerProperties -contains 'priority') { $priorityConfigured = $true }
            if ($providerProperties -notcontains 'api-key-entries') { continue }
            foreach ($entry in @($provider.'api-key-entries')) {
                if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains 'weight') {
                    $weightConfigured = $true
                }
            }
        }
    }

    $strategy = 'round-robin'
    $sessionAffinityEnabled = $false
    $sessionAffinityTtl = '1h'
    if ($payload.PSObject.Properties.Name -contains 'routing' -and $null -ne $payload.routing) {
        $routingProperties = @($payload.routing.PSObject.Properties.Name)
        if ($routingProperties -contains 'strategy') {
            $candidate = $payload.routing.strategy
            $strategy = if ($candidate -in @('round-robin', 'weighted-round-robin', 'fill-first')) { $candidate } else { $null }
        }
        if ($routingProperties -contains 'session-affinity') {
            $candidate = $payload.routing.'session-affinity'
            $sessionAffinityEnabled = if ($candidate -is [bool]) { $candidate } else { $null }
        }
        if ($routingProperties -contains 'session-affinity-ttl') {
            $candidate = $payload.routing.'session-affinity-ttl'
            $sessionAffinityTtl = if ($candidate -is [string] -and $candidate -match '^(?:[0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h))+$') { $candidate } else { $null }
        }
    }

    return [pscustomobject][ordered]@{
        priority_configured = $priorityConfigured
        weight_configured = $weightConfigured
        strategy = $strategy
        session_affinity_enabled = $sessionAffinityEnabled
        session_affinity_ttl = $sessionAffinityTtl
    }
}

function ConvertFrom-RoutingStrategyCapability($content) {
    try {
        $payload = $content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $payload -or $payload.PSObject.Properties.Name -notcontains 'strategy') { return $null }
    if ($payload.strategy -notin @('round-robin', 'weighted-round-robin', 'fill-first')) { return $null }
    return $payload.strategy
}

function ConvertFrom-ManagementCenterVersion($content) {
    if (-not ($content -is [string]) -or -not $content) { return $null }
    $pattern = 'footer\.version.{0,300}?tileValue.{0,160}?children:\s*[`"](?<version>v[0-9]+\.[0-9]+\.[0-9]+)[`"]'
    $match = [regex]::Match($content, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { return $null }
    return $match.Groups['version'].Value
}

function Merge-CapabilityConfiguredFlag($first, $second) {
    if ($first -eq $true -or $second -eq $true) { return $true }
    if ($first -eq $false -and $second -eq $false) { return $false }
    return $null
}

function New-PluginCapability {
    return [pscustomobject][ordered]@{
        inspection = 'unavailable'
        reason = $null
        source = $null
        count = $null
        items = @()
    }
}

function ConvertFrom-PluginCapability($content) {
    try {
        $payload = $content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not ($payload.PSObject.Properties.Name -contains 'plugins')) { return $null }

    $items = [System.Collections.Generic.List[object]]::new()
    $configured = $false
    $index = 0
    foreach ($plugin in @($payload.plugins)) {
        $index++
        if ($null -eq $plugin) { continue }
        $propertyNames = @($plugin.PSObject.Properties.Name)
        if ($propertyNames -contains 'configured' -and $plugin.configured -eq $true) { $configured = $true }
        $pluginId = if ($propertyNames -contains 'id' -and $plugin.id -is [string]) { $plugin.id.Trim() } else { '' }
        if ($pluginId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { $pluginId = "redacted-plugin-$index" }
        $metadata = if ($propertyNames -contains 'metadata' -and $null -ne $plugin.metadata) { $plugin.metadata } else { $null }
        $name = if ($metadata -and $metadata.PSObject.Properties.Name -contains 'name' -and $metadata.name -is [string]) { $metadata.name.Trim() }
            elseif ($propertyNames -contains 'name' -and $plugin.name -is [string]) { $plugin.name.Trim() }
            else { $pluginId }
        if (-not $name -or $name.Length -gt 80 -or $name -match '[@\\/]|://|[\x00-\x1f]' -or $name -notmatch '^[A-Za-z0-9 ._()+-]+$') {
            $name = $pluginId
        }
        $version = if ($metadata -and $metadata.PSObject.Properties.Name -contains 'version' -and $metadata.version -is [string]) { $metadata.version.Trim() }
            elseif ($propertyNames -contains 'version' -and $plugin.version -is [string]) { $plugin.version.Trim() }
            else { $null }
        if ($version -and $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$') { $version = $null }
        $enabled = if ($propertyNames -contains 'effective_enabled' -and $plugin.effective_enabled -is [bool]) { $plugin.effective_enabled }
            elseif ($propertyNames -contains 'enabled' -and $plugin.enabled -is [bool]) { $plugin.enabled }
            else { $null }
        $menuCount = if ($propertyNames -contains 'menus' -and $null -ne $plugin.menus) { @($plugin.menus).Count } else { 0 }
        $items.Add([pscustomobject][ordered]@{
            id = $pluginId
            name = $name
            version = $version
            enabled = $enabled
            menu_count = $menuCount
        }) | Out-Null
    }
    $systemEnabled = if ($payload.PSObject.Properties.Name -contains 'plugins_enabled' -and $payload.plugins_enabled -is [bool]) { $payload.plugins_enabled } else { $null }
    return [pscustomobject][ordered]@{
        plugins = [pscustomobject][ordered]@{
            inspection = 'available'
            reason = $null
            source = 'management_api'
            count = $items.Count
            items = @($items)
        }
        configured = $configured
        enabled = $systemEnabled
    }
}

function Get-CpaBuildMetadataFromLogs($containerRunning) {
    $result = [ordered]@{ version = $null; commit = $null }
    if ($containerRunning -ne $true) { return [pscustomobject]$result }
    $native = Invoke-ReadOnlyNative -File 'docker' -Arguments @('logs', '--tail', '5000', $script:CONTAINER_NAME)
    foreach ($line in $native.Output) {
        if ($line -match 'CLIProxyAPI\s+Version:\s*(v?\d+\.\d+\.\d+)') {
            $result.version = $Matches[1]
            if ($line -match 'Commit:\s*([0-9a-fA-F]+)') {
                $candidate = $Matches[1]
                if ($candidate.Length -ge 7 -and $candidate.Length -le 40) { $result.commit = $candidate }
            }
        }
    }
    return [pscustomobject]$result
}

function Get-PluginBinarySupport($containerRunning) {
    if ($containerRunning -ne $true) { return $null }
    $scriptText = 'if ! command -v ldd >/dev/null 2>&1; then printf unknown; elif ldd /proc/1/exe >/dev/null 2>&1; then printf true; else printf false; fi'
    $native = Invoke-ReadOnlyNative -File 'docker' -Arguments @('exec', $script:CONTAINER_NAME, 'sh', '-c', $scriptText)
    if ($native.ExitCode -ne 0 -or $native.Output.Count -eq 0) { return $null }
    return ConvertTo-CapabilityBoolean $native.Output[0]
}

function Get-AuditedCpaContract($version, $commit) {
    if (-not $version -or -not $commit) { return $null }
    if (($version -eq 'v7.2.102' -or $version -eq '7.2.102') -and $commit.StartsWith('8423cce')) {
        return 'v7.2.102'
    }
    if (($version -eq $script:RELEASE_CONTRACT_CPA_VERSION -or $version -eq $script:RELEASE_CONTRACT_CPA_VERSION.TrimStart('v')) -and
        $script:RELEASE_CONTRACT_CPA_COMMIT.StartsWith($commit)) {
        return 'v7.2.111'
    }
    return $null
}

function Test-AuditedCpaContract($version, $commit) {
    return [bool](Get-AuditedCpaContract $version $commit)
}

function Get-LatestCpaBackupTime {
    $backupDir = Join-Path $script:SCRIPT_DIR 'backups'
    if (-not (Test-Path $backupDir -PathType Container)) { return $null }
    $latest = Get-ChildItem -LiteralPath $backupDir -File -Filter '*.tgz' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -notmatch '^sub2api' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $latest) { return $null }
    return $latest.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Add-CapabilityFinding($list, $code, $severity, $message) {
    $list.Add([pscustomobject][ordered]@{
        code = $code
        severity = $severity
        message = $message
    }) | Out-Null
}

function Get-CpaCapabilityProbe {
    $findings = [System.Collections.Generic.List[object]]::new()
    $configuredAddress = if ($env:CPA_BIND_HOST) { $env:CPA_BIND_HOST } else { '127.0.0.1' }
    $configuredPortRaw = if ($script:CPA_PORT) { $script:CPA_PORT.ToString() } else { '8317' }
    $configuredPortParsed = 0
    $configuredPort = if ([int]::TryParse($configuredPortRaw, [ref]$configuredPortParsed)) { $configuredPortParsed } else { $null }
    $actualAddress = $null
    $actualPort = $null
    $containerRunning = $null
    $imageReference = $script:DOCKER_IMAGE
    $imageLocalId = $null
    $repositoryDigest = $null
    $cpaVersion = $null
    $cpaCommit = $null
    $apiHealthy = $null
    $healthHttpStatus = $null
    $modelsHttpStatus = $null
    $modelCount = $null
    $previousImageAvailable = $null
    $managementUiEnabled = $null
    $managementUiReachable = $null
    $managementUiHttpStatus = $null
    $managementUiLocalUrl = $null
    $managementUiVersion = $null
    $managementUiVersionSource = $null
    $managementUiExternalHttps = $null
    $managementUiPublicWarning = $null
    $managementAuthenticated = $null
    $managementConfigHttpStatus = $null
    $officialContractSource = $null
    $managementApiAvailable = $null
    $authFilesInventorySupported = $null
    $accountStatusSupported = $null
    $priorityReadSupported = $null
    $priorityWriteSupported = $null
    $quotaResetSupported = $null
    $routingStrategySupported = $null
    $pluginSystemSupported = $null
    $pluginResourceManagementAuthenticated = $null
    $pluginResourceVerification = $null
    $criticalPublicPluginResourceExposure = $null
    $configPriorityConfigured = $null
    $configWeightConfigured = $null
    $authFilesPriorityConfigured = $null
    $authFilesWeightConfigured = $null
    $weightedRoundRobinSupported = $null
    $prioritySupported = $null
    $sessionAffinitySupported = $null
    $automaticFailoverSupported = $null
    $wrrTrafficValidation = 'not_run'
    $releaseCompatibilityStatus = $null
    $plugins = New-PluginCapability
    $credentials = New-ProviderCredentialCapability

    $configState = if (Test-Path $script:CONFIG_FILE -PathType Container) { 'directory' }
        elseif (Test-Path $script:CONFIG_FILE -PathType Leaf) { 'file' }
        else { 'missing' }
    $configApiKeyCount = if ($configState -eq 'file') { @(Get-ConfigApiKeys).Count } else { $null }

    $dockerCli = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
    $dockerDaemon = $false
    if ($dockerCli) {
        $dockerInfo = Invoke-ReadOnlyNative -File 'docker' -Arguments @('info')
        $dockerDaemon = $dockerInfo.ExitCode -eq 0
    }

    $script:COMPOSE_CMD = detect-compose
    $composeAvailable = [bool]$script:COMPOSE_CMD
    $composeValid = $null
    if ($composeAvailable -and $configState -eq 'file') {
        $composeParts = $script:COMPOSE_CMD -split '\s+'
        $composeArgs = @()
        if ($composeParts.Count -gt 1) { $composeArgs += $composeParts[1..($composeParts.Count - 1)] }
        $composeArgs += @('-f', $script:COMPOSE_FILE, 'config', '--quiet')
        $composeResult = Invoke-ReadOnlyNative -File $composeParts[0] -Arguments $composeArgs
        $composeValid = $composeResult.ExitCode -eq 0
    }

    if ($dockerDaemon) {
        $containerResult = Invoke-ReadOnlyNative -File 'docker' -Arguments @(
            'inspect', '--format', '{{.Config.Image}}|{{.Image}}|{{.State.Running}}', $script:CONTAINER_NAME
        )
        if ($containerResult.ExitCode -eq 0 -and $containerResult.Output.Count -gt 0) {
            $containerParts = $containerResult.Output[0] -split '\|', 3
            if ($containerParts.Count -eq 3) {
                if ($containerParts[0]) { $imageReference = $containerParts[0] }
                if ($containerParts[1]) { $imageLocalId = $containerParts[1] }
                $containerRunning = ConvertTo-CapabilityBoolean $containerParts[2]
            }
        } else {
            $containerRunning = $false
            $imageResult = Invoke-ReadOnlyNative -File 'docker' -Arguments @('image', 'inspect', '--format', '{{.Id}}', $imageReference)
            if ($imageResult.ExitCode -eq 0 -and $imageResult.Output.Count -gt 0) {
                $imageLocalId = $imageResult.Output[0]
            }
        }

        if ($containerRunning -eq $true) {
            $portResult = Invoke-ReadOnlyNative -File 'docker' -Arguments @('port', $script:CONTAINER_NAME, '8317/tcp')
            if ($portResult.ExitCode -eq 0) {
                $binding = Select-CapabilityBinding $portResult.Output
                if ($binding) {
                    $actualAddress = $binding.Address
                    $actualPort = $binding.Port
                }
            }
        }

        $imageTarget = if ($imageLocalId) { $imageLocalId } else { $imageReference }
        $digestResult = Invoke-ReadOnlyNative -File 'docker' -Arguments @(
            'image', 'inspect', '--format', '{{range .RepoDigests}}{{println .}}{{end}}', $imageTarget
        )
        if ($digestResult.ExitCode -eq 0) {
            $repositoryDigest = @($digestResult.Output | Where-Object { $_ } | Select-Object -First 1)
            if ($repositoryDigest.Count -gt 0) { $repositoryDigest = $repositoryDigest[0] } else { $repositoryDigest = $null }
        }

        $rollbackResult = Invoke-ReadOnlyNative -File 'docker' -Arguments @('image', 'inspect', $script:ROLLBACK_IMAGE)
        $previousImageAvailable = $rollbackResult.ExitCode -eq 0

        $buildMetadata = Get-CpaBuildMetadataFromLogs $containerRunning
        $cpaVersion = $buildMetadata.version
        $cpaCommit = $buildMetadata.commit
        $pluginSystemSupported = Get-PluginBinarySupport $containerRunning
    }

    $classificationAddress = if ($actualAddress) { $actualAddress } else { $configuredAddress }
    $exposureHint = if ($env:CPA_EXPOSURE_MODE) { $env:CPA_EXPOSURE_MODE.ToLowerInvariant() } else { '' }
    $exposureMode = if (-not $classificationAddress) { 'unknown' }
        elseif (Test-CapabilityLoopback $classificationAddress) {
            if ($exposureHint -eq 'public-proxy') { 'public-proxy' } else { 'local' }
        } else { 'direct-public' }

    $remoteManagement = Get-RemoteManagementCapability
    $routingConfig = Get-RoutingConfigCapability
    $routingStrategy = $routingConfig.strategy
    $sessionAffinityEnabled = $routingConfig.session_affinity_enabled
    $sessionAffinityTtl = $routingConfig.session_affinity_ttl
    $pluginConfig = Get-PluginConfigCapability
    $latestBackupTime = Get-LatestCpaBackupTime

    $probePort = if ($null -ne $actualPort) { $actualPort } else { $configuredPort }
    $probeAddress = if ($actualAddress) { $actualAddress } else { $configuredAddress }
    if ($containerRunning -eq $true -and $null -ne $probePort) {
        $requestHost = Get-CapabilityProbeHost $probeAddress
        $baseUri = "http://${requestHost}:$probePort"
        $managementUiLocalUrl = "$baseUri/management.html"

        $healthResponse = Invoke-CapabilityWebRequest -Uri "$baseUri/healthz"
        $healthHttpStatus = $healthResponse.StatusCode

        $managementPageResponse = Invoke-CapabilityWebRequest -Uri $managementUiLocalUrl
        $managementUiHttpStatus = $managementPageResponse.StatusCode
        if ($managementUiHttpStatus -eq 200) {
            $managementUiReachable = $true
            $managementUiEnabled = $true
            $managementUiVersion = ConvertFrom-ManagementCenterVersion $managementPageResponse.Content
            if ($managementUiVersion) { $managementUiVersionSource = 'management_html' }
        } elseif ($null -ne $managementUiHttpStatus) {
            $managementUiReachable = $false
        }

        Sync-ApiKeyFromConfig
        if ($script:CPA_API_KEY) {
            $modelsResponse = Invoke-CapabilityWebRequest -Uri "$baseUri/v1/models" `
                -Headers @{ Authorization = "Bearer $($script:CPA_API_KEY)" }
            $modelsHttpStatus = $modelsResponse.StatusCode
            if ($modelsHttpStatus -eq 200) {
                try {
                    $modelsJson = $modelsResponse.Content | ConvertFrom-Json -ErrorAction Stop
                    if ($modelsJson.PSObject.Properties.Name -contains 'data') {
                        $modelCount = @($modelsJson.data).Count
                    } elseif ($modelsJson.PSObject.Properties.Name -contains 'models') {
                        $modelCount = @($modelsJson.models).Count
                    } else {
                        $modelCount = 0
                    }
                } catch {
                    $modelCount = $null
                }
            }
        }

        if ($healthHttpStatus -eq 200 -or $modelsHttpStatus -eq 200) { $apiHealthy = $true }
        elseif ($null -ne $healthHttpStatus -or $null -ne $modelsHttpStatus) { $apiHealthy = $false }

        if ($script:CPA_MANAGEMENT_KEY) {
            $managementHeaders = @{ Authorization = "Bearer $($script:CPA_MANAGEMENT_KEY)" }
            $metadataResponse = Invoke-CapabilityWebRequest -Uri "$baseUri/v0/management/config" -Headers $managementHeaders
            $managementConfigHttpStatus = $metadataResponse.StatusCode
            if ($managementConfigHttpStatus -eq 200) {
                $managementAuthenticated = $true
                $managementApiAvailable = $true
                $headerVersion = Get-CapabilityHeaderValue $metadataResponse.Headers 'X-CPA-VERSION'
                $headerCommit = Get-CapabilityHeaderValue $metadataResponse.Headers 'X-CPA-COMMIT'
                if ($headerVersion) { $cpaVersion = $headerVersion }
                if ($headerCommit) { $cpaCommit = $headerCommit }
                $pluginHeader = Get-CapabilityHeaderValue $metadataResponse.Headers 'X-CPA-SUPPORT-PLUGIN'
                if ($pluginHeader -in @('1', 'true')) { $pluginSystemSupported = $true }
                elseif ($pluginHeader -in @('0', 'false')) { $pluginSystemSupported = $false }

                $managementConfig = ConvertFrom-ManagementConfigCapability $metadataResponse.Content
                if ($managementConfig) {
                    $configPriorityConfigured = $managementConfig.priority_configured
                    $configWeightConfigured = $managementConfig.weight_configured
                    $routingStrategy = $managementConfig.strategy
                    $sessionAffinityEnabled = $managementConfig.session_affinity_enabled
                    $sessionAffinityTtl = $managementConfig.session_affinity_ttl
                }

                $authFilesResponse = Invoke-CapabilityWebRequest -Uri "$baseUri/v0/management/auth-files" -Headers $managementHeaders
                if ($authFilesResponse.StatusCode -eq 200) {
                    $authFiles = ConvertFrom-AuthFilesCapability $authFilesResponse.Content
                    if ($authFiles) {
                        $credentials = $authFiles.credentials
                        $authFilesInventorySupported = $true
                        if ($authFiles.status_supported) { $accountStatusSupported = $true }
                        if ($authFiles.priority_supported) { $priorityReadSupported = $true }
                        $authFilesPriorityConfigured = $authFiles.priority_configured
                        $authFilesWeightConfigured = $authFiles.weight_configured
                    }
                }

                $pluginResponse = Invoke-CapabilityWebRequest -Uri "$baseUri/v0/management/plugins" -Headers $managementHeaders
                if ($pluginResponse.StatusCode -eq 200) {
                    $pluginData = ConvertFrom-PluginCapability $pluginResponse.Content
                    if ($pluginData) {
                        $plugins = $pluginData.plugins
                        $pluginSystemSupported = $true
                        if ($pluginData.configured) { $pluginConfig.configured = $true }
                        if ($null -ne $pluginData.enabled) { $pluginConfig.enabled = $pluginData.enabled }
                    }
                } else {
                    $plugins.reason = 'plugin_api_unavailable'
                }

                $routingResponse = Invoke-CapabilityWebRequest -Uri "$baseUri/v0/management/routing/strategy" -Headers $managementHeaders
                if ($routingResponse.StatusCode -eq 200) {
                    $routingStrategySupported = $true
                    $observedRoutingStrategy = ConvertFrom-RoutingStrategyCapability $routingResponse.Content
                    if ($observedRoutingStrategy) { $routingStrategy = $observedRoutingStrategy }
                }
            } elseif ($managementConfigHttpStatus -in @(401, 403)) {
                $managementAuthenticated = $false
                $managementApiAvailable = $true
                $plugins.reason = 'management_key_rejected'
            } else {
                $plugins.reason = 'management_api_unavailable'
            }
        } else {
            $plugins.reason = 'management_key_unavailable'
        }
    }

    $auditedContract = Get-AuditedCpaContract $cpaVersion $cpaCommit
    if ($auditedContract) {
        $officialContractSource = if ($managementAuthenticated -eq $true) { 'live_and_audited' } else { "audited_$auditedContract" }
        $managementApiAvailable = $true
        $authFilesInventorySupported = $true
        $accountStatusSupported = $true
        $priorityReadSupported = $true
        $priorityWriteSupported = $true
        $quotaResetSupported = $true
        $routingStrategySupported = $true
        $pluginResourceManagementAuthenticated = $false
        $pluginResourceVerification = "audited_$auditedContract"
        $prioritySupported = $true
        if ($auditedContract -eq 'v7.2.111') {
            $cpaVersion = $script:RELEASE_CONTRACT_CPA_VERSION
            $cpaCommit = $script:RELEASE_CONTRACT_CPA_COMMIT
            $weightedRoundRobinSupported = $true
            $sessionAffinitySupported = $true
            $automaticFailoverSupported = $true
        }
        if (-not $pluginConfig.section_present) {
            $pluginConfig.configured = $false
            $pluginConfig.enabled = $false
        }
    } elseif ($managementAuthenticated -eq $true) {
        $officialContractSource = 'live'
    }

    if ($credentials.source -ne 'management_api') {
        $credentials = Get-ProviderCredentialFallbackCapability $containerRunning
    }
    $priorityConfigured = Merge-CapabilityConfiguredFlag $configPriorityConfigured $authFilesPriorityConfigured
    $credentialWeightsConfigured = Merge-CapabilityConfiguredFlag $configWeightConfigured $authFilesWeightConfigured
    $weightedRoundRobinConfigured = if ($routingStrategy -eq 'weighted-round-robin') { $true }
        elseif ($routingStrategy -in @('round-robin', 'fill-first')) { $false }
        else { $null }

    if ($cpaVersion -eq $script:RELEASE_CONTRACT_CPA_VERSION -or $cpaVersion -eq $script:RELEASE_CONTRACT_CPA_VERSION.TrimStart('v')) {
        if (-not $cpaCommit) {
            $releaseCompatibilityStatus = $null
        } elseif (-not $script:RELEASE_CONTRACT_CPA_COMMIT.StartsWith($cpaCommit)) {
            $releaseCompatibilityStatus = 'cpa_commit_mismatch'
        } elseif (-not $managementUiVersion) {
            $releaseCompatibilityStatus = $null
        } elseif ($managementUiVersion -eq $script:RELEASE_CONTRACT_MANAGEMENT_CENTER_VERSION) {
            $releaseCompatibilityStatus = 'compatible'
        } else {
            $releaseCompatibilityStatus = 'management_center_mismatch'
        }
    } elseif ($cpaVersion) {
        $releaseCompatibilityStatus = 'cpa_version_mismatch'
    }
    if ($null -eq $managementUiEnabled) {
        if ($remoteManagement.control_panel_disabled -eq $true) { $managementUiEnabled = $false }
        elseif ($remoteManagement.control_panel_disabled -eq $false) { $managementUiEnabled = $true }
    }
    if ($exposureMode -eq 'local' -or $managementUiEnabled -eq $false) {
        $managementUiPublicWarning = 'none'
    } elseif ($exposureMode -eq 'direct-public' -and $managementUiEnabled -eq $true -and $remoteManagement.allow_remote -eq $true) {
        $managementUiPublicWarning = 'critical'
    } elseif ($exposureMode -in @('direct-public', 'public-proxy')) {
        $managementUiPublicWarning = 'warning'
    }
    if ($pluginResourceManagementAuthenticated -eq $false -and $pluginSystemSupported -eq $true) {
        $criticalPublicPluginResourceExposure = ($exposureMode -eq 'direct-public' -and $remoteManagement.allow_remote -eq $true)
    }

    if (-not $dockerCli) {
        Add-CapabilityFinding $findings 'DOCKER_CLI_UNAVAILABLE' 'failure' 'Docker CLI is unavailable.'
    } elseif (-not $dockerDaemon) {
        Add-CapabilityFinding $findings 'DOCKER_DAEMON_UNAVAILABLE' 'failure' 'Docker daemon is unavailable.'
    }
    if (-not $composeAvailable) {
        Add-CapabilityFinding $findings 'COMPOSE_UNAVAILABLE' 'failure' 'Docker Compose is unavailable.'
    } elseif ($composeValid -eq $false) {
        Add-CapabilityFinding $findings 'COMPOSE_CONFIG_INVALID' 'failure' 'docker-compose.yml did not pass validation.'
    }
    if ($null -eq $configuredPort) {
        Add-CapabilityFinding $findings 'INVALID_CONFIGURED_PORT' 'failure' 'CPA_PORT is not a valid number.'
    }
    if ($configState -eq 'directory') {
        Add-CapabilityFinding $findings 'CONFIG_IS_DIRECTORY' 'failure' 'config.yaml is a directory, not a file.'
    } elseif ($configState -eq 'missing') {
        Add-CapabilityFinding $findings 'CONFIG_MISSING' 'failure' 'config.yaml is missing.'
    } elseif ($configApiKeyCount -eq 0) {
        Add-CapabilityFinding $findings 'API_KEYS_MISSING' 'failure' 'No API keys were found in config.yaml.'
    }
    if ($containerRunning -eq $false) {
        Add-CapabilityFinding $findings 'CONTAINER_NOT_RUNNING' 'warning' 'The CPA container is not running.'
    } elseif ($containerRunning -eq $true -and -not $actualAddress) {
        Add-CapabilityFinding $findings 'PORT_MAPPING_UNAVAILABLE' 'warning' 'The actual CPA port mapping could not be read.'
    }
    if ($exposureMode -eq 'direct-public') {
        Add-CapabilityFinding $findings 'DIRECT_PUBLIC_EXPOSURE' 'warning' "CPA is bound directly to a public interface (${classificationAddress}:$probePort)."
        Add-CapabilityFinding $findings 'PUBLIC_PROTECTION_UNVERIFIED' 'warning' 'TLS, firewall/source limits, and rate limits cannot be verified by this local probe.'
        if ($remoteManagement.allow_remote -eq $true) {
            Add-CapabilityFinding $findings 'REMOTE_MANAGEMENT_PUBLIC' 'warning' 'Remote management is allowed while CPA is directly public.'
            if ($remoteManagement.control_panel_disabled -eq $false) {
                Add-CapabilityFinding $findings 'PUBLIC_CONTROL_PANEL_ENABLED' 'warning' 'The management control panel is enabled on the direct-public CPA endpoint.'
            }
            if ($remoteManagement.secret_configured -eq $false) {
                Add-CapabilityFinding $findings 'REMOTE_MANAGEMENT_SECRET_MISSING' 'failure' 'Remote management is public but no management secret is configured.'
            }
        }
    } elseif ($exposureMode -eq 'public-proxy') {
        Add-CapabilityFinding $findings 'PUBLIC_PROXY_PROTECTION_UNVERIFIED' 'warning' 'External HTTPS and proxy access controls cannot be verified by this local probe.'
    }
    if ($managementUiEnabled -eq $true -and $managementUiReachable -eq $false) {
        Add-CapabilityFinding $findings 'MANAGEMENT_UI_UNREACHABLE' 'warning' 'The management UI is enabled but its local page did not return HTTP 200.'
    }
    if ($criticalPublicPluginResourceExposure -eq $true) {
        Add-CapabilityFinding $findings 'PUBLIC_PLUGIN_RESOURCES_UNAUTHENTICATED' 'critical' 'CPA plugin resource pages are not protected by management authentication while remote management is exposed over direct-public HTTP.'
    }
    if ($pluginSystemSupported -eq $true -and $plugins.inspection -ne 'available') {
        Add-CapabilityFinding $findings 'PLUGIN_INSPECTION_UNAVAILABLE' 'warning' 'Plugin support is available, but installed plugins could not be inspected through the authenticated Management API.'
    }
    if ($exposureHint -eq 'public-proxy' -and $exposureMode -eq 'direct-public') {
        Add-CapabilityFinding $findings 'EXPOSURE_HINT_MISMATCH' 'warning' 'CPA_EXPOSURE_MODE says public-proxy, but the actual binding is public.'
    }
    if ($containerRunning -eq $true) {
        if ($apiHealthy -eq $false) {
            Add-CapabilityFinding $findings 'API_UNHEALTHY' 'failure' 'The local CPA health check failed.'
        } elseif ($null -eq $apiHealthy) {
            Add-CapabilityFinding $findings 'API_HEALTH_UNKNOWN' 'warning' 'The local CPA health check could not be completed.'
        }
        if ($modelsHttpStatus -eq 401) {
            Add-CapabilityFinding $findings 'MODELS_AUTH_FAILED' 'failure' '/v1/models rejected the configured API key.'
        } elseif ($null -eq $modelsHttpStatus) {
            Add-CapabilityFinding $findings 'MODELS_CHECK_UNKNOWN' 'warning' '/v1/models could not be checked.'
        } elseif ($modelsHttpStatus -eq 200 -and $modelCount -eq 0) {
            Add-CapabilityFinding $findings 'MODELS_EMPTY' 'warning' '/v1/models is healthy but returned no models.'
        }
    }
    if ($credentials.inspection -eq 'unknown') {
        Add-CapabilityFinding $findings 'CREDENTIAL_INSPECTION_UNKNOWN' 'warning' 'Provider credential counts could not be inspected read-only.'
    } elseif ($credentials.total -eq 0) {
        Add-CapabilityFinding $findings 'NO_PROVIDER_CREDENTIALS' 'warning' 'No provider credentials were found.'
    }
    if (-not $latestBackupTime) {
        Add-CapabilityFinding $findings 'NO_CPA_BACKUP' 'warning' 'No CPA backup archive was found.'
    }
    if ($previousImageAvailable -eq $false) {
        Add-CapabilityFinding $findings 'NO_PREVIOUS_IMAGE' 'warning' 'No previous-image recovery target is available.'
    }

    $data = [pscustomobject][ordered]@{
        schema_version = 1
        generated_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        manager = [pscustomobject][ordered]@{
            version = $script:VERSION
        }
        container = [pscustomobject][ordered]@{
            name = $script:CONTAINER_NAME
            running = $containerRunning
        }
        network = [pscustomobject][ordered]@{
            configured_address = $configuredAddress
            configured_port = $configuredPort
            actual_address = $actualAddress
            actual_port = $actualPort
            exposure_mode = $exposureMode
        }
        image = [pscustomobject][ordered]@{
            reference = $imageReference
            local_id = $imageLocalId
            repository_digest = $repositoryDigest
        }
        cpa = [pscustomobject][ordered]@{
            version = $cpaVersion
            commit = $cpaCommit
        }
        release_contract = [pscustomobject][ordered]@{
            cpa_version = $script:RELEASE_CONTRACT_CPA_VERSION
            cpa_commit = $script:RELEASE_CONTRACT_CPA_COMMIT
            management_center_version = $script:RELEASE_CONTRACT_MANAGEMENT_CENTER_VERSION
            management_center_commit = $script:RELEASE_CONTRACT_MANAGEMENT_CENTER_COMMIT
            source = 'exact_release_tags'
            target_pair_compatible = $true
            compatibility_status = $releaseCompatibilityStatus
        }
        api = [pscustomobject][ordered]@{
            healthy = $apiHealthy
            health_http_status = $healthHttpStatus
            models_http_status = $modelsHttpStatus
            model_count = $modelCount
        }
        remote_management = $remoteManagement
        management_ui = [pscustomobject][ordered]@{
            enabled = $managementUiEnabled
            reachable = $managementUiReachable
            http_status = $managementUiHttpStatus
            local_url = $managementUiLocalUrl
            version = $managementUiVersion
            version_source = $managementUiVersionSource
            remote_access_allowed = $remoteManagement.allow_remote
            external_https_protection = $managementUiExternalHttps
            public_access_warning = $managementUiPublicWarning
        }
        official_capabilities = [pscustomobject][ordered]@{
            contract_source = $officialContractSource
            management_api_available = $managementApiAvailable
            auth_files_inventory_supported = $authFilesInventorySupported
            account_status_supported = $accountStatusSupported
            priority_read_supported = $priorityReadSupported
            priority_write_supported = $priorityWriteSupported
            quota_reset_supported = $quotaResetSupported
            routing_strategy_supported = $routingStrategySupported
            plugin_system_supported = $pluginSystemSupported
            plugin_system_configured = $pluginConfig.configured
            plugin_system_enabled = $pluginConfig.enabled
        }
        routing = [pscustomobject][ordered]@{
            strategy = $routingStrategy
            weighted_round_robin_supported = $weightedRoundRobinSupported
            weighted_round_robin_configured = $weightedRoundRobinConfigured
            priority_supported = $prioritySupported
            priority_configured = $priorityConfigured
            credential_weights_configured = $credentialWeightsConfigured
            session_affinity_supported = $sessionAffinitySupported
            session_affinity_enabled = $sessionAffinityEnabled
            session_affinity_ttl = $sessionAffinityTtl
            automatic_failover_supported = $automaticFailoverSupported
            wrr_traffic_validation = $wrrTrafficValidation
        }
        plugins = $plugins
        security = [pscustomobject][ordered]@{
            plugin_resource_pages_management_authenticated = $pluginResourceManagementAuthenticated
            plugin_resource_pages_verification = $pluginResourceVerification
            critical_public_plugin_resource_exposure = $criticalPublicPluginResourceExposure
        }
        credentials = $credentials
        recovery = [pscustomobject][ordered]@{
            latest_backup_time = $latestBackupTime
            previous_image_available = $previousImageAvailable
        }
        warnings = @($findings)
    }
    $diagnostics = [pscustomobject][ordered]@{
        docker_cli = $dockerCli
        docker_daemon = $dockerDaemon
        compose_available = $composeAvailable
        compose_command = $script:COMPOSE_CMD
        compose_valid = $composeValid
        config_state = $configState
        config_api_key_count = $configApiKeyCount
        management_authenticated = $managementAuthenticated
        management_config_http_status = $managementConfigHttpStatus
    }
    return [pscustomobject]@{ Data = $data; Diagnostics = $diagnostics }
}

function Format-CapabilityValue($value) {
    if ($null -eq $value) { return 'unavailable' }
    if ($value -is [string] -and $value.Length -eq 0) { return 'unavailable' }
    return $value.ToString()
}

function Format-CapabilityBoolean($value) {
    if ($value -eq $true) { return 'yes' }
    if ($value -eq $false) { return 'no' }
    return 'unavailable'
}

function Write-CpaCapabilitiesHuman($data) {
    Write-Host ''
    Write-Host "  CLI Proxy Manager capabilities (schema v$($data.schema_version))"
    Write-Host ''
    Write-Host "  Manager version:          $($data.manager.version)"
    Write-Host "  CPA container running:    $(Format-CapabilityBoolean $data.container.running)"
    Write-Host "  Configured binding:       $($data.network.configured_address):$(Format-CapabilityValue $data.network.configured_port)"
    if ($data.network.actual_address) {
        Write-Host "  Actual binding:           $($data.network.actual_address):$(Format-CapabilityValue $data.network.actual_port)"
    } else {
        Write-Host '  Actual binding:           unavailable'
    }
    Write-Host "  Exposure mode:            $(Format-CapabilityValue $data.network.exposure_mode)"
    Write-Host "  Image reference:          $(Format-CapabilityValue $data.image.reference)"
    Write-Host "  Local image ID:           $(Format-CapabilityValue $data.image.local_id)"
    Write-Host "  Repository digest:        $(Format-CapabilityValue $data.image.repository_digest)"
    Write-Host "  CPA version:              $(Format-CapabilityValue $data.cpa.version)"
    Write-Host "  CPA commit:               $(Format-CapabilityValue $data.cpa.commit)"
    Write-Host "  Release contract:         CPA $($data.release_contract.cpa_version)@$($data.release_contract.cpa_commit), Management Center $($data.release_contract.management_center_version)@$($data.release_contract.management_center_commit)"
    Write-Host "  Contract compatibility:   source=$($data.release_contract.source), target_pair=$(Format-CapabilityBoolean $data.release_contract.target_pair_compatible), runtime=$(Format-CapabilityValue $data.release_contract.compatibility_status)"
    Write-Host "  API healthy:              $(Format-CapabilityBoolean $data.api.healthy) (healthz=$(Format-CapabilityValue $data.api.health_http_status), models=$(Format-CapabilityValue $data.api.models_http_status))"
    Write-Host "  Model count:              $(Format-CapabilityValue $data.api.model_count)"
    Write-Host "  Remote management:        configured=$(Format-CapabilityBoolean $data.remote_management.configured), allow_remote=$(Format-CapabilityBoolean $data.remote_management.allow_remote), panel_disabled=$(Format-CapabilityBoolean $data.remote_management.control_panel_disabled), secret_configured=$(Format-CapabilityBoolean $data.remote_management.secret_configured)"
    Write-Host "  Management UI:            enabled=$(Format-CapabilityBoolean $data.management_ui.enabled), reachable=$(Format-CapabilityBoolean $data.management_ui.reachable), http=$(Format-CapabilityValue $data.management_ui.http_status)"
    Write-Host "  Management Center:        version=$(Format-CapabilityValue $data.management_ui.version), source=$(Format-CapabilityValue $data.management_ui.version_source)"
    Write-Host "  Management local URL:     $(Format-CapabilityValue $data.management_ui.local_url)"
    Write-Host "  Management protection:    remote_allowed=$(Format-CapabilityBoolean $data.management_ui.remote_access_allowed), external_https=$(Format-CapabilityBoolean $data.management_ui.external_https_protection), public_warning=$(Format-CapabilityValue $data.management_ui.public_access_warning)"
    Write-Host "  Official capabilities:    management_api=$(Format-CapabilityBoolean $data.official_capabilities.management_api_available), auth_files=$(Format-CapabilityBoolean $data.official_capabilities.auth_files_inventory_supported), account_status=$(Format-CapabilityBoolean $data.official_capabilities.account_status_supported)"
    Write-Host "  Priority and routing:     priority_read=$(Format-CapabilityBoolean $data.official_capabilities.priority_read_supported), priority_write=$(Format-CapabilityBoolean $data.official_capabilities.priority_write_supported), quota_reset=$(Format-CapabilityBoolean $data.official_capabilities.quota_reset_supported), routing=$(Format-CapabilityBoolean $data.official_capabilities.routing_strategy_supported)"
    Write-Host "  Routing contract:         strategy=$(Format-CapabilityValue $data.routing.strategy), wrr_supported=$(Format-CapabilityBoolean $data.routing.weighted_round_robin_supported), wrr_configured=$(Format-CapabilityBoolean $data.routing.weighted_round_robin_configured)"
    Write-Host "  Credential routing:       priority_supported=$(Format-CapabilityBoolean $data.routing.priority_supported), priority_configured=$(Format-CapabilityBoolean $data.routing.priority_configured), weights_configured=$(Format-CapabilityBoolean $data.routing.credential_weights_configured)"
    Write-Host "  Session affinity:         supported=$(Format-CapabilityBoolean $data.routing.session_affinity_supported), enabled=$(Format-CapabilityBoolean $data.routing.session_affinity_enabled), ttl=$(Format-CapabilityValue $data.routing.session_affinity_ttl)"
    Write-Host "  Failover / WRR test:      automatic_failover=$(Format-CapabilityBoolean $data.routing.automatic_failover_supported), traffic_validation=$($data.routing.wrr_traffic_validation)"
    Write-Host "  Plugin system:            supported=$(Format-CapabilityBoolean $data.official_capabilities.plugin_system_supported), configured=$(Format-CapabilityBoolean $data.official_capabilities.plugin_system_configured), enabled=$(Format-CapabilityBoolean $data.official_capabilities.plugin_system_enabled), inspection=$($data.plugins.inspection)"
    if ($data.plugins.inspection -eq 'available') {
        Write-Host "  Installed plugins:        $($data.plugins.count)"
        foreach ($plugin in $data.plugins.items) {
            Write-Host "    - $($plugin.id) | $($plugin.name) | version=$(Format-CapabilityValue $plugin.version) | enabled=$(Format-CapabilityBoolean $plugin.enabled) | menus=$($plugin.menu_count)"
        }
    } else {
        Write-Host "  Plugin inspection reason: $(Format-CapabilityValue $data.plugins.reason)"
    }
    Write-Host "  Plugin resource auth:     management_authenticated=$(Format-CapabilityBoolean $data.security.plugin_resource_pages_management_authenticated), verification=$(Format-CapabilityValue $data.security.plugin_resource_pages_verification)"
    if ($data.credentials.inspection -eq 'available') {
        Write-Host "  Provider credentials:     source=$($data.credentials.source), antigravity=$($data.credentials.providers.antigravity), claude=$($data.credentials.providers.claude), codex=$($data.credentials.providers.codex), gemini=$($data.credentials.providers.gemini), kimi=$($data.credentials.providers.kimi), xai=$($data.credentials.providers.xai), unknown=$($data.credentials.providers.unknown), total=$($data.credentials.total)"
        foreach ($provider in $data.credentials.additional_providers) {
            Write-Host "    - future provider $($provider.type)=$($provider.count)"
        }
    } else {
        Write-Host '  Provider credentials:     unavailable'
    }
    Write-Host "  Latest CPA backup time:   $(Format-CapabilityValue $data.recovery.latest_backup_time)"
    Write-Host "  Previous image available: $(Format-CapabilityBoolean $data.recovery.previous_image_available)"
    if ($data.warnings.Count -gt 0) {
        Write-Host ''
        Write-Host '  Findings:'
        foreach ($finding in $data.warnings) {
            Write-Host "  - [$($finding.severity)] $($finding.code): $($finding.message)"
        }
    }
    Write-Host ''
}

function cmd-capabilities {
    param([string[]]$Options = @())
    if ($Options.Count -gt 1 -or ($Options.Count -eq 1 -and $Options[0] -ne '--json')) {
        error-msg '用法: .\deploy.ps1 capabilities [--json]'
        exit 2
    }
    $probe = Get-CpaCapabilityProbe
    if ($Options.Count -eq 1 -and $Options[0] -eq '--json') {
        $probe.Data | ConvertTo-Json -Depth 8
    } else {
        Write-CpaCapabilitiesHuman $probe.Data
    }
}

function Resolve-BackupPath($requestedPath) {
    if (-not $requestedPath) {
        $backupDir = Join-Path $script:SCRIPT_DIR 'backups'
        return (Join-Path $backupDir ("cli-proxy-manager-backup-{0}.tgz" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
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

function Get-DockerImageId($image) {
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $imageId = docker image inspect --format '{{.Id}}' $image 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $imageId) { return '' }
        return ($imageId | Select-Object -First 1)
    } catch {
        return ''
    } finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
}

function Set-DockerImageTag($source, $target) {
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        docker image tag $source $target 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    } finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
}

function Save-CurrentImageForRollback {
    $currentId = Get-DockerImageId $script:DOCKER_IMAGE
    if (-not $currentId) {
        try {
            $currentId = docker inspect --format '{{.Image}}' $script:CONTAINER_NAME 2>$null
            if ($LASTEXITCODE -ne 0) { $currentId = '' }
        } catch { $currentId = '' }
    }

    if (-not $currentId) {
        warn '未找到当前镜像，无法创建回滚点'
        return $false
    }

    if (-not (Set-DockerImageTag $currentId $script:ROLLBACK_IMAGE)) {
        warn '保存回滚镜像失败'
        return $false
    }

    info '已保存更新前镜像'
    detail "回滚镜像: $($script:ROLLBACK_IMAGE)"
    return $true
}

function Test-ServiceHealth($attempts = 30, $delaySeconds = 1) {
    Sync-ApiKeyFromConfig

    for ($i = 0; $i -lt $attempts; $i++) {
        try {
            $headers = @{}
            if ($script:CPA_API_KEY) {
                $headers.Authorization = "Bearer $($script:CPA_API_KEY)"
            }
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$($script:CPA_PORT)/v1/models" `
                -Headers $headers -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ([int]$response.StatusCode -eq 200) { return $true }
        } catch {
            if (-not $script:CPA_API_KEY -and $_.Exception.Response -and
                [int]$_.Exception.Response.StatusCode -eq 401) {
                return $true
            }
        }
        Start-Sleep -Seconds $delaySeconds
    }

    return $false
}

function Invoke-ServiceRecreate {
    Push-Location $script:SCRIPT_DIR
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    $previousPort = $env:CPA_PORT
    $previousImage = $env:CPA_IMAGE
    $previousPullPolicy = $env:CPA_PULL_POLICY
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $env:CPA_PORT = $script:CPA_PORT
        $env:CPA_IMAGE = $script:DOCKER_IMAGE
        $env:CPA_PULL_POLICY = 'never'
        $output = Invoke-Compose -f $script:COMPOSE_FILE up -d --force-recreate 2>&1
        $composeExitCode = $LASTEXITCODE
        if ($output) { detail ([string]($output | Select-Object -Last 1)) }
        return $composeExitCode -eq 0
    } catch {
        detail $_.Exception.Message
        return $false
    } finally {
        if ($null -eq $previousPort) { Remove-Item Env:CPA_PORT -ErrorAction SilentlyContinue } else { $env:CPA_PORT = $previousPort }
        if ($null -eq $previousImage) { Remove-Item Env:CPA_IMAGE -ErrorAction SilentlyContinue } else { $env:CPA_IMAGE = $previousImage }
        if ($null -eq $previousPullPolicy) { Remove-Item Env:CPA_PULL_POLICY -ErrorAction SilentlyContinue } else { $env:CPA_PULL_POLICY = $previousPullPolicy }
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
        Pop-Location
    }
}

function Invoke-SavedImageRollback {
    $previousCurrentId = Get-DockerImageId $script:DOCKER_IMAGE
    $rollbackId = Get-DockerImageId $script:ROLLBACK_IMAGE

    if (-not $rollbackId) {
        error-msg '没有可用的回滚镜像'
        detail '先成功运行一次 update，脚本才会保存更新前镜像'
        return $false
    }

    if ($previousCurrentId -eq $rollbackId) {
        warn '当前镜像与回滚镜像相同，无需回滚'
        return $true
    }

    if (-not (Set-DockerImageTag $rollbackId $script:DOCKER_IMAGE)) {
        error-msg '无法将回滚镜像切换为当前镜像'
        return $false
    }
    if ($previousCurrentId) {
        $null = Set-DockerImageTag $previousCurrentId $script:ROLLBACK_IMAGE
    }

    if ((Invoke-ServiceRecreate) -and (Test-ServiceHealth)) {
        info '镜像回滚成功'
        return $true
    }

    error-msg '回滚后的服务健康检查失败，正在恢复回滚前镜像'
    if ($previousCurrentId) {
        $null = Set-DockerImageTag $previousCurrentId $script:DOCKER_IMAGE
        $null = Set-DockerImageTag $rollbackId $script:ROLLBACK_IMAGE
        $null = Invoke-ServiceRecreate
    }
    return $false
}

function Invoke-TransactionalUpdate {
    $rollbackAvailable = Save-CurrentImageForRollback

    step '拉取最新镜像'
    detail $script:DOCKER_IMAGE
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    $oldNativePreference = $null
    $pullExitCode = 1
    try {
        if ($hasNativePreference) {
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $pullOutput = docker pull $script:DOCKER_IMAGE 2>&1
        $pullExitCode = $LASTEXITCODE
        if ($pullOutput) { detail ([string]($pullOutput | Select-Object -Last 1)) }
    } catch {
        detail $_.Exception.Message
    } finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }

    if ($pullExitCode -ne 0) {
        error-msg '镜像拉取失败；现有服务保持不变'
        return $false
    }

    step '重建并检查服务'
    if (-not (Invoke-ServiceRecreate)) {
        error-msg '新容器启动失败'
        if ($rollbackAvailable) {
            warn '正在自动回滚'
            $null = Invoke-SavedImageRollback
        }
        return $false
    }

    if (Test-ServiceHealth) {
        info '更新完成，API 健康检查通过'
        detail '手动回滚: .\deploy.ps1 rollback'
        return $true
    }

    error-msg '新版本未通过 /v1/models 健康检查'
    if ($rollbackAvailable) {
        warn '正在自动回滚到更新前镜像'
        $null = Invoke-SavedImageRollback
    } else {
        error-msg '没有更新前镜像，无法自动回滚'
    }
    return $false
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
        info '管理面板: 启用'
    } else {
        $script:CPA_MANAGEMENT_KEY = ''
        info '管理面板: 禁用'
    }

    # Debug mode
    $debugMode = 'false'
    if (confirm-prompt '是否开启调试日志？(首次部署建议开启)' 'y') {
        $debugMode = 'true'
    }

    # File logging (logging-to-file)
    $loggingMode = 'false'
    if (confirm-prompt '是否开启文件日志？(logging-to-file，便于在面板 Logs 页查看)' 'y') {
        $loggingMode = 'true'
    }

    # Plugin system (plugins.enabled)
    $pluginsMode = 'false'
    if (confirm-prompt '是否启用插件系统？(plugins.enabled，安装插件后才会生效)' 'y') {
        $pluginsMode = 'true'
    }

    divider

    # Generate config.yaml
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $apiKeysYaml = ($script:CPA_API_KEYS | ForEach-Object {
        '  - "' + (ConvertTo-YamlDoubleQuotedValue $_) + '"'
    }) -join [Environment]::NewLine
    $configContent = @"
# =============================================================================
#  CLI Proxy Manager 配置文件
#  由 deploy.ps1 自动生成于 $timestamp
# =============================================================================

host: ""
port: 8317

auth-dir: "/root/.cli-proxy-api"

api-keys:
$apiKeysYaml

debug: $debugMode

usage-statistics-enabled: true
logging-to-file: $loggingMode

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
  secret-key: "$($script:CPA_MANAGEMENT_KEY)"
  disable-control-panel: false

plugins:
  enabled: $pluginsMode
  dir: "plugins"
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
        detail '检测到本地镜像；仍会连接仓库确认并拉取目标镜像'
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
        return
    }

    error-msg '镜像拉取失败；未使用本地缓存冒充最新版本'
    $pullOutput |
        Where-Object { $_ } |
        Select-Object -Last 3 |
        ForEach-Object { detail $_ }
    if ($hasLocalImage -or (Test-DockerImageExists $script:DOCKER_IMAGE)) {
        detail '本地缓存仍保留，可在修复网络后重试，或显式设置 CPA_PULL_POLICY=never'
    }
    exit 1

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
    pull-image

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

        # 镜像已在停止旧容器前拉取，避免 Compose 重复访问仓库
        $env:CPA_PORT = $script:CPA_PORT
        $env:CPA_IMAGE = $script:DOCKER_IMAGE
        $previousPullPolicy = $env:CPA_PULL_POLICY
        $env:CPA_PULL_POLICY = 'never'
        try {
            $upResult = Invoke-Compose -f $script:COMPOSE_FILE up -d 2>&1 | Select-Object -Last 1
        } finally {
            if ($null -eq $previousPullPolicy) { Remove-Item Env:CPA_PULL_POLICY -ErrorAction SilentlyContinue }
            else { $env:CPA_PULL_POLICY = $previousPullPolicy }
        }


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
        Write-Host '  面板密码  已设置（不回显）' -ForegroundColor DarkGray
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
    Write-Host '  .\deploy.ps1 update     安全更新到最新版本' -ForegroundColor Cyan
    Write-Host '  .\deploy.ps1 rollback   回滚到上一个镜像版本' -ForegroundColor Cyan
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
            try { Start-CursorBridgeSidecarIfReady } catch { warn $_.Exception.Message }
            show-result
            return
        }

        warn '将覆盖现有 config.yaml 与全部 API key'
    }

    config-wizard

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
    try { Start-CursorBridgeSidecarIfReady } catch { warn $_.Exception.Message }
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
    try { Start-CursorBridgeSidecarIfReady } catch { warn $_.Exception.Message }

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
        try { Connect-CursorBridgeCpa } catch { }
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
    step 'Doctor v2 read-only check'

    $probe = Get-CpaCapabilityProbe
    $data = $probe.Data
    $diagnostics = $probe.Diagnostics
    $failures = 0
    $warnings = 0

    if ($diagnostics.docker_cli) { info 'Docker CLI is available' }
    if ($diagnostics.docker_daemon) { info 'Docker daemon is available' }
    if ($diagnostics.compose_available) { info "Docker Compose is available ($($diagnostics.compose_command))" }
    if ($diagnostics.config_state -eq 'file') {
        info "config.yaml is a file; API key count: $(Format-CapabilityValue $diagnostics.config_api_key_count)"
    }
    if ($diagnostics.compose_valid -eq $true) { info 'docker-compose.yml is valid' }
    if ($data.container.running -eq $true) { info "CPA container is running: $($data.container.name)" }

    info "Configured binding: $($data.network.configured_address):$(Format-CapabilityValue $data.network.configured_port)"
    if ($data.network.actual_address) {
        info "Actual binding: $($data.network.actual_address):$(Format-CapabilityValue $data.network.actual_port)"
    }
    info "Exposure mode: $(Format-CapabilityValue $data.network.exposure_mode)"

    if ($data.image.local_id) {
        info 'CPA image is available locally'
        detail "Reference: $($data.image.reference)"
        detail "Image ID: $($data.image.local_id)"
        detail "Repository digest: $(Format-CapabilityValue $data.image.repository_digest)"
    }
    if ($data.cpa.version -or $data.cpa.commit) {
        info 'CPA build metadata is available'
        detail "Version: $(Format-CapabilityValue $data.cpa.version)"
        detail "Commit: $(Format-CapabilityValue $data.cpa.commit)"
    } else {
        info 'CPA build metadata is unavailable from the local API'
    }
    info "D2.2 release contract: CPA $($data.release_contract.cpa_version)@$($data.release_contract.cpa_commit), Management Center $($data.release_contract.management_center_version)@$($data.release_contract.management_center_commit)"
    detail "contract-source=$($data.release_contract.source), target-pair-compatible=$(Format-CapabilityBoolean $data.release_contract.target_pair_compatible), runtime-compatibility=$(Format-CapabilityValue $data.release_contract.compatibility_status)"
    if ($data.api.healthy -eq $true) { info 'CPA API is healthy' }
    if ($data.api.models_http_status -eq 200) {
        info "/v1/models returned 200; model count: $(Format-CapabilityValue $data.api.model_count)"
    }

    info "Remote management: configured=$(Format-CapabilityBoolean $data.remote_management.configured), allow_remote=$(Format-CapabilityBoolean $data.remote_management.allow_remote), panel_disabled=$(Format-CapabilityBoolean $data.remote_management.control_panel_disabled), secret_configured=$(Format-CapabilityBoolean $data.remote_management.secret_configured)"
    info "Management UI: enabled=$(Format-CapabilityBoolean $data.management_ui.enabled), reachable=$(Format-CapabilityBoolean $data.management_ui.reachable), HTTP=$(Format-CapabilityValue $data.management_ui.http_status)"
    detail "Management Center version=$(Format-CapabilityValue $data.management_ui.version), source=$(Format-CapabilityValue $data.management_ui.version_source)"
    detail "Safe local URL: $(Format-CapabilityValue $data.management_ui.local_url)"
    detail "External HTTPS protection: $(Format-CapabilityBoolean $data.management_ui.external_https_protection)"
    info "Official Management API support: $(Format-CapabilityBoolean $data.official_capabilities.management_api_available) (contract=$(Format-CapabilityValue $data.official_capabilities.contract_source))"
    detail "auth-files=$(Format-CapabilityBoolean $data.official_capabilities.auth_files_inventory_supported), account-status=$(Format-CapabilityBoolean $data.official_capabilities.account_status_supported), priority-read=$(Format-CapabilityBoolean $data.official_capabilities.priority_read_supported), priority-write=$(Format-CapabilityBoolean $data.official_capabilities.priority_write_supported)"
    detail "quota-reset=$(Format-CapabilityBoolean $data.official_capabilities.quota_reset_supported), routing-strategy=$(Format-CapabilityBoolean $data.official_capabilities.routing_strategy_supported)"
    info "Routing: strategy=$(Format-CapabilityValue $data.routing.strategy), weighted-supported=$(Format-CapabilityBoolean $data.routing.weighted_round_robin_supported), weighted-configured=$(Format-CapabilityBoolean $data.routing.weighted_round_robin_configured)"
    detail "priority-supported=$(Format-CapabilityBoolean $data.routing.priority_supported), priority-configured=$(Format-CapabilityBoolean $data.routing.priority_configured), credential-weights-configured=$(Format-CapabilityBoolean $data.routing.credential_weights_configured)"
    detail "session-affinity-supported=$(Format-CapabilityBoolean $data.routing.session_affinity_supported), enabled=$(Format-CapabilityBoolean $data.routing.session_affinity_enabled), ttl=$(Format-CapabilityValue $data.routing.session_affinity_ttl), automatic-failover=$(Format-CapabilityBoolean $data.routing.automatic_failover_supported), WRR-traffic-validation=$($data.routing.wrr_traffic_validation)"
    info "CPA plugin system: supported=$(Format-CapabilityBoolean $data.official_capabilities.plugin_system_supported), configured=$(Format-CapabilityBoolean $data.official_capabilities.plugin_system_configured), enabled=$(Format-CapabilityBoolean $data.official_capabilities.plugin_system_enabled)"
    if ($data.plugins.inspection -eq 'available') {
        detail "Installed plugin count: $($data.plugins.count)"
    } else {
        detail "Plugin inspection unavailable: $(Format-CapabilityValue $data.plugins.reason)"
    }
    detail "Plugin resource pages use management authentication: $(Format-CapabilityBoolean $data.security.plugin_resource_pages_management_authenticated)"
    if ($data.credentials.inspection -eq 'available') {
        info 'Provider credential counts are available'
        detail "source=$($data.credentials.source), antigravity=$($data.credentials.providers.antigravity), claude=$($data.credentials.providers.claude), codex=$($data.credentials.providers.codex), gemini=$($data.credentials.providers.gemini), kimi=$($data.credentials.providers.kimi), xai=$($data.credentials.providers.xai), unknown=$($data.credentials.providers.unknown), total=$($data.credentials.total)"
    }
    if ($data.recovery.latest_backup_time) { info "Latest CPA backup: $($data.recovery.latest_backup_time)" }
    if ($data.recovery.previous_image_available -eq $true) { info 'Previous-image recovery target is available' }

    foreach ($finding in $data.warnings) {
        if ($finding.severity -eq 'failure') {
            error-msg "$($finding.code): $($finding.message)"
            $failures++
        } elseif ($finding.severity -eq 'critical') {
            warn "CRITICAL $($finding.code): $($finding.message)"
            $warnings++
        } else {
            warn "$($finding.code): $($finding.message)"
            $warnings++
        }
    }

    Write-Host ''
    divider
    if ($failures -eq 0) {
        info "Doctor v2 completed: $warnings warning(s), 0 failure(s)"
    } else {
        error-msg "Doctor v2 completed: $warnings warning(s), $failures failure(s)"
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

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cli-proxy-manager-backup-{0}" -f [guid]::NewGuid())
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
        detail '用法: .\deploy.ps1 restore backups\cli-proxy-manager-backup-YYYYmmdd-HHMMSS.tgz'
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

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cli-proxy-manager-restore-{0}" -f [guid]::NewGuid())
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

    step '更新到最新版本'
    if (-not (Invoke-TransactionalUpdate)) { exit 1 }
}

function cmd-rollback {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }
    require-config-file

    step '回滚 Docker 镜像'
    detail $script:ROLLBACK_IMAGE
    if (-not (Invoke-SavedImageRollback)) { exit 1 }
}

function cmd-uninstall {
    $script:COMPOSE_CMD = detect-compose
    if (-not $script:COMPOSE_CMD) { error-msg 'Docker Compose 不可用'; exit 1 }

    Write-Host ''
    warn '即将完全卸载 CLI Proxy Manager'
    Write-Host ''

    if (-not (confirm-prompt '确认卸载？(这将删除容器、凭证卷和配置文件)' 'n')) {
        info '取消卸载'
        return
    }

    Push-Location $script:SCRIPT_DIR
    try {
        $env:CPA_PORT = $script:CPA_PORT
        Invoke-Compose -f $script:COMPOSE_FILE down 2>$null
    } catch { error-msg '停止现有栈失败，卸载已中止'; exit 1 }
    finally { Pop-Location }

    if (confirm-prompt "是否删除 OAuth 凭证卷 ($($script:AUTH_VOLUME))？" 'n') {
        $authExists = $false
        try { Invoke-NativeChecked 'docker' @('volume','inspect',$script:AUTH_VOLUME) | Out-Null; $authExists = $true } catch { }
        if ($authExists) {
            try { Invoke-NativeChecked 'docker' @('volume','rm',$script:AUTH_VOLUME) | Out-Null } catch { error-msg 'OAuth 凭证卷删除失败'; exit 1 }
            $authRemains = $false
            try { Invoke-NativeChecked 'docker' @('volume','inspect',$script:AUTH_VOLUME) | Out-Null; $authRemains = $true } catch { }
            if ($authRemains) { error-msg 'OAuth 凭证卷仍然存在'; exit 1 }
        }
    } else { warn 'OAuth 凭证卷已保留；这不是无残留卸载' }

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

# ========================== Sub2API companion stack ===========================

function Require-Sub2ApiCompose {
    try { $null = Get-Command docker -ErrorAction Stop }
    catch { throw '未检测到 Docker' }

    $null = docker info 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Docker 守护进程未运行' }

    $null = docker compose version 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Sub2API 功能要求 Docker Compose v2' }

    $script:COMPOSE_CMD = 'docker compose'
    Assert-RegularFile $script:SUB2API_COMPOSE_FILE
}

function Invoke-Sub2ApiCompose {
    $previousProject = $env:COMPOSE_PROJECT_NAME
    $env:COMPOSE_PROJECT_NAME = $script:SUB2API_PROJECT_NAME
    try {
        $composeArgs = @('--env-file', $script:SUB2API_ENV_FILE, '-f', $script:SUB2API_COMPOSE_FILE)
        $postgresMode = Get-Sub2ApiEnvValue 'SUB2API_POSTGRES_MODE'
        $redisMode = Get-Sub2ApiEnvValue 'SUB2API_REDIS_MODE'
        if (-not $postgresMode -or $postgresMode -eq 'managed') { $composeArgs += @('--profile', 'managed-postgres') }
        if (-not $redisMode -or $redisMode -eq 'managed') { $composeArgs += @('--profile', 'managed-redis') }
        Invoke-Compose @composeArgs @args
    } finally {
        if ($null -eq $previousProject) { Remove-Item Env:COMPOSE_PROJECT_NAME -ErrorAction SilentlyContinue }
        else { $env:COMPOSE_PROJECT_NAME = $previousProject }
    }
}

function Invoke-Sub2ApiComposeAll {
    $previousProject = $env:COMPOSE_PROJECT_NAME
    $env:COMPOSE_PROJECT_NAME = $script:SUB2API_PROJECT_NAME
    try {
        Invoke-Compose --env-file $script:SUB2API_ENV_FILE -f $script:SUB2API_COMPOSE_FILE `
            --profile managed-postgres --profile managed-redis @args
    } finally {
        if ($null -eq $previousProject) { Remove-Item Env:COMPOSE_PROJECT_NAME -ErrorAction SilentlyContinue }
        else { $env:COMPOSE_PROJECT_NAME = $previousProject }
    }
}

function New-CryptoHex([int]$byteCount = 32) {
    $bytes = New-Object byte[] $byteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

function Set-Sub2ApiEnvPermissions($path) {
    if (-not $IsWindows) {
        & chmod 600 $path 2>$null
        return
    }
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($currentIdentity, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $path -AclObject $acl
}

function Get-Sub2ApiEnvValue($key) {
    if (-not (Test-Path $script:SUB2API_ENV_FILE -PathType Leaf)) { return '' }
    foreach ($line in Get-Content $script:SUB2API_ENV_FILE) {
        if ($line -match "^$([regex]::Escape($key))=(.*)$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return ''
}

function Test-Sub2ApiPortInUse([int]$port) {
    try {
        $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        if ($listeners | Where-Object Port -eq $port) { return $true }
    } catch { }
    try {
        $publishedPorts = docker ps --format '{{.Ports}}' 2>$null
        if ($publishedPorts -match "(^|[.:])$port->") { return $true }
    } catch { }
    return $false
}

function Get-AvailableSub2ApiPort {
    foreach ($port in @(8321, 18321, 28321, 38321, 48321)) {
        if (-not (Test-Sub2ApiPortInUse $port)) { return $port }
    }
    throw '无法找到可用的 Sub2API 宿主端口'
}

function New-Sub2ApiEnvironment {
    $script:SUB2API_ENV_CREATED = $false
    $script:SUB2API_NEW_ADMIN_PASSWORD = ''

    if (Test-Path $script:SUB2API_ENV_FILE) {
        Assert-RegularFile $script:SUB2API_ENV_FILE
        Set-Sub2ApiEnvPermissions $script:SUB2API_ENV_FILE
        return
    }

    Assert-SafeRepoPath $script:SUB2API_ENV_FILE $true
    Assert-RegularFile $script:SUB2API_ENV_EXAMPLE_FILE

    $postgresPassword = New-CryptoHex 24
    $redisPassword = New-CryptoHex 24
    $adminPassword = New-CryptoHex 18
    $jwtSecret = New-CryptoHex 32
    $totpKey = New-CryptoHex 32
    $hostPort = Get-AvailableSub2ApiPort
    $tempFile = "$($script:SUB2API_ENV_FILE).tmp.$([guid]::NewGuid().ToString('N'))"
    Assert-SafeRepoPath $tempFile $true

    $content = @"
# Generated by CLI Proxy Manager. Keep this file private.
SUB2API_BIND_HOST=127.0.0.1
SUB2API_PORT=$hostPort
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
SUB2API_POSTGRES_PASSWORD=$postgresPassword
SUB2API_POSTGRES_DB=sub2api
SUB2API_DATABASE_SSLMODE=disable
SUB2API_REDIS_MODE=managed
SUB2API_REDIS_HOST=redis
SUB2API_REDIS_PORT=6379
SUB2API_REDIS_PASSWORD=$redisPassword
SUB2API_REDIS_DB=0
SUB2API_ADMIN_EMAIL=admin@sub2api.local
SUB2API_ADMIN_PASSWORD=$adminPassword
SUB2API_JWT_SECRET=$jwtSecret
SUB2API_TOTP_ENCRYPTION_KEY=$totpKey
SUB2API_URL_ALLOWLIST_ENABLED=false
SUB2API_ALLOW_INSECURE_HTTP=true
SUB2API_ALLOW_PRIVATE_HOSTS=true
"@

    try {
        [IO.File]::WriteAllText($tempFile, $content, [Text.UTF8Encoding]::new($false))
        Set-Sub2ApiEnvPermissions $tempFile
        if (Test-Path $script:SUB2API_ENV_FILE) { throw 'sub2api.env 已被其他进程创建，请重试' }
        Move-Item -LiteralPath $tempFile -Destination $script:SUB2API_ENV_FILE
    } finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }

    $script:SUB2API_ENV_CREATED = $true
    $script:SUB2API_NEW_ADMIN_PASSWORD = $adminPassword
}

function Test-Sub2ApiEnvironment {
    Assert-RegularFile $script:SUB2API_ENV_FILE
    foreach ($key in @(
        'SUB2API_POSTGRES_PASSWORD',
        'SUB2API_ADMIN_PASSWORD',
        'SUB2API_JWT_SECRET',
        'SUB2API_TOTP_ENCRYPTION_KEY'
    )) {
        if (-not (Get-Sub2ApiEnvValue $key)) { throw "sub2api.env 缺少 $key" }
    }

    $postgresMode = Get-Sub2ApiEnvValue 'SUB2API_POSTGRES_MODE'
    $redisMode = Get-Sub2ApiEnvValue 'SUB2API_REDIS_MODE'
    if (-not $postgresMode) { $postgresMode = 'managed' }
    if (-not $redisMode) { $redisMode = 'managed' }
    if ($postgresMode -notin @('managed', 'external')) {
        throw 'SUB2API_POSTGRES_MODE 只能是 managed 或 external'
    }
    if ($redisMode -notin @('managed', 'external')) {
        throw 'SUB2API_REDIS_MODE 只能是 managed 或 external'
    }

    $databaseHost = Get-Sub2ApiEnvValue 'SUB2API_DATABASE_HOST'
    $redisHost = Get-Sub2ApiEnvValue 'SUB2API_REDIS_HOST'
    if ($postgresMode -eq 'external' -and -not $databaseHost) {
        throw 'external PostgreSQL 模式要求 SUB2API_DATABASE_HOST'
    }
    if ($redisMode -eq 'external' -and -not $redisHost) {
        throw 'external Redis 模式要求 SUB2API_REDIS_HOST'
    }
    if (-not $databaseHost) { $databaseHost = 'postgres' }
    if (-not $redisHost) { $redisHost = 'redis' }
    if ($postgresMode -eq 'managed' -and $databaseHost -ne 'postgres') {
        throw 'managed PostgreSQL 模式要求 SUB2API_DATABASE_HOST=postgres'
    }
    if ($redisMode -eq 'managed' -and $redisHost -ne 'redis') {
        throw 'managed Redis 模式要求 SUB2API_REDIS_HOST=redis'
    }
    if ($postgresMode -eq 'external' -and $databaseHost -in @('127.0.0.1', 'localhost')) {
        throw '外部 PostgreSQL 在宿主机时请使用 host.docker.internal，不能使用 localhost'
    }
    if ($redisMode -eq 'external' -and $redisHost -in @('127.0.0.1', 'localhost')) {
        throw '外部 Redis 在宿主机时请使用 host.docker.internal，不能使用 localhost'
    }
    if ($redisMode -eq 'managed' -and -not (Get-Sub2ApiEnvValue 'SUB2API_REDIS_PASSWORD')) {
        throw 'managed Redis 模式要求 SUB2API_REDIS_PASSWORD'
    }

    foreach ($key in @('SUB2API_DATABASE_PORT', 'SUB2API_REDIS_PORT')) {
        $dependencyPortText = Get-Sub2ApiEnvValue $key
        if (-not $dependencyPortText) { continue }
        $dependencyPort = 0
        if (-not [int]::TryParse($dependencyPortText, [ref]$dependencyPort) -or $dependencyPort -lt 1 -or $dependencyPort -gt 65535) {
            throw "$key 必须是 1..65535 的整数"
        }
    }

    $bindHost = Get-Sub2ApiEnvValue 'SUB2API_BIND_HOST'
    if (-not $bindHost) { $bindHost = '127.0.0.1' }
    if ($bindHost -notin @('127.0.0.1', '0.0.0.0')) {
        throw 'SUB2API_BIND_HOST 仅支持 127.0.0.1 或 0.0.0.0'
    }

    $portText = Get-Sub2ApiEnvValue 'SUB2API_PORT'
    if (-not $portText) { $portText = '8321' }
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw 'SUB2API_PORT 必须是 1..65535 的整数'
    }
}

function Wait-Sub2ApiContainer($containerName, $label) {
    Write-Host "     等待 $label 就绪 " -NoNewline
    for ($i = 0; $i -lt 60; $i++) {
        $health = docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerName 2>$null
        if ($LASTEXITCODE -eq 0 -and $health -eq 'healthy') {
            Write-Host ''
            return $true
        }
        if ($health -in @('exited', 'dead')) {
            Write-Host ''
            return $false
        }
        Write-Host '·' -NoNewline
        Start-Sleep -Seconds 2
    }
    Write-Host ''
    return $false
}

function Start-Sub2ApiStack([switch]$ForceRecreate) {
    $postgresMode = Get-Sub2ApiEnvValue 'SUB2API_POSTGRES_MODE'
    $redisMode = Get-Sub2ApiEnvValue 'SUB2API_REDIS_MODE'
    if (-not $postgresMode) { $postgresMode = 'managed' }
    if (-not $redisMode) { $redisMode = 'managed' }
    $managedServices = @()

    if ($postgresMode -eq 'managed') { $managedServices += 'postgres' }
    else { try { Invoke-Sub2ApiComposeAll stop postgres } catch { } }
    if ($redisMode -eq 'managed') { $managedServices += 'redis' }
    else { try { Invoke-Sub2ApiComposeAll stop redis } catch { } }

    if ($managedServices.Count -gt 0) { Invoke-Sub2ApiCompose up -d @managedServices }
    if ($postgresMode -eq 'managed' -and -not (Wait-Sub2ApiContainer $script:SUB2API_POSTGRES_CONTAINER_NAME 'PostgreSQL')) {
        return $false
    }
    if ($redisMode -eq 'managed' -and -not (Wait-Sub2ApiContainer $script:SUB2API_REDIS_CONTAINER_NAME 'Redis')) {
        return $false
    }

    $appArgs = @('up', '-d')
    if ($ForceRecreate) { $appArgs += '--force-recreate' }
    $appArgs += 'sub2api'
    Invoke-Sub2ApiCompose @appArgs
    return (Wait-Sub2ApiContainer $script:SUB2API_CONTAINER_NAME 'Sub2API')
}

function Show-Sub2ApiResult {
    $bindHost = Get-Sub2ApiEnvValue 'SUB2API_BIND_HOST'
    $port = Get-Sub2ApiEnvValue 'SUB2API_PORT'
    $adminEmail = Get-Sub2ApiEnvValue 'SUB2API_ADMIN_EMAIL'
    if (-not $bindHost -or $bindHost -eq '0.0.0.0') { $bindHost = '127.0.0.1' }
    if (-not $port) { $port = '8321' }
    if (-not $adminEmail) { $adminEmail = 'admin@sub2api.local' }

    detail "访问地址: http://${bindHost}:$port"
    detail "管理员邮箱: $adminEmail"
    $postgresMode = Get-Sub2ApiEnvValue 'SUB2API_POSTGRES_MODE'
    $redisMode = Get-Sub2ApiEnvValue 'SUB2API_REDIS_MODE'
    if (-not $postgresMode) { $postgresMode = 'managed' }
    if (-not $redisMode) { $redisMode = 'managed' }
    detail "PostgreSQL 模式: $postgresMode"
    detail "Redis 模式: $redisMode"
    detail "配置文件: $($script:SUB2API_ENV_FILE)"
    if ($script:SUB2API_ENV_CREATED) {
        detail "首次管理员密码: $($script:SUB2API_NEW_ADMIN_PASSWORD)"
        warn '请立即保存密码，并保护 sub2api.env'
    }
}

function Initialize-Sub2Api {
    Require-Sub2ApiCompose
    New-Sub2ApiEnvironment
    Test-Sub2ApiEnvironment
    Invoke-Sub2ApiCompose config --quiet
}

function cmd-sub2api-init {
    try {
        step '生成 Sub2API 配置'
        Assert-RegularFile $script:SUB2API_COMPOSE_FILE
        New-Sub2ApiEnvironment
        Test-Sub2ApiEnvironment
        info 'Sub2API 配置已准备'
        detail "配置文件: $($script:SUB2API_ENV_FILE)"
        detail '默认模式: managed PostgreSQL + managed Redis'
        warn '如需混合部署，请先编辑两个 MODE 和对应的 HOST/PORT，再运行 deploy'
        if ($script:SUB2API_ENV_CREATED) {
            detail "首次管理员密码: $($script:SUB2API_NEW_ADMIN_PASSWORD)"
            warn '请立即保存密码，并保护 sub2api.env'
        }
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-deploy {
    try {
        step '一键部署 Sub2API'
        Initialize-Sub2Api
        Invoke-Sub2ApiCompose pull
        if (-not (Start-Sub2ApiStack)) {
            try { Invoke-Sub2ApiCompose logs --tail 80 sub2api } catch { }
            throw 'Sub2API 未通过健康检查'
        }
        info 'Sub2API 已启动'
        Show-Sub2ApiResult
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-start {
    try {
        step '启动 Sub2API'
        Initialize-Sub2Api
        if (-not (Start-Sub2ApiStack)) { throw 'Sub2API 或托管依赖未通过健康检查' }
        info 'Sub2API 已启动'
        Show-Sub2ApiResult
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-stop {
    try {
        Require-Sub2ApiCompose
        Assert-RegularFile $script:SUB2API_ENV_FILE
        step '停止 Sub2API'
        Invoke-Sub2ApiComposeAll stop
        info 'Sub2API 已停止，数据卷已保留'
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-restart {
    try {
        step '重建并重启 Sub2API'
        Initialize-Sub2Api
        if (-not (Start-Sub2ApiStack -ForceRecreate)) { throw 'Sub2API 或托管依赖未通过健康检查' }
        info 'Sub2API 已重新启动'
        Show-Sub2ApiResult
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-status {
    try {
        Require-Sub2ApiCompose
        Assert-RegularFile $script:SUB2API_ENV_FILE
        step 'Sub2API 状态'
        Invoke-Sub2ApiComposeAll ps
        $health = docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $script:SUB2API_CONTAINER_NAME 2>$null
        if (-not $health) { $health = 'not-created' }
        detail "应用健康状态: $health"
        Show-Sub2ApiResult
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-logs($service = 'sub2api') {
    try {
        Require-Sub2ApiCompose
        Assert-RegularFile $script:SUB2API_ENV_FILE
        Invoke-Sub2ApiComposeAll logs -f --tail 200 $service
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-update {
    try {
        step '更新 Sub2API 栈'
        Initialize-Sub2Api
        Invoke-Sub2ApiCompose pull
        if (-not (Start-Sub2ApiStack)) {
            try { Invoke-Sub2ApiCompose logs --tail 80 sub2api } catch { }
            throw '更新后健康检查失败'
        }
        info 'Sub2API 已更新并通过健康检查'
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-doctor {
    try {
        step '检查 Sub2API 部署'
        Require-Sub2ApiCompose
        Assert-RegularFile $script:SUB2API_ENV_FILE
        Test-Sub2ApiEnvironment
        Invoke-Sub2ApiCompose config --quiet
        info 'Compose 配置有效'
        $bindHost = Get-Sub2ApiEnvValue 'SUB2API_BIND_HOST'
        if ($bindHost -eq '0.0.0.0') {
            warn 'Sub2API 当前对所有网络接口开放'
            detail '请使用防火墙和 HTTPS 反向代理'
        } else { info 'Sub2API 仅绑定本机' }
        cmd-sub2api-status
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function cmd-sub2api-uninstall {
    try {
        Require-Sub2ApiCompose
        Assert-RegularFile $script:SUB2API_ENV_FILE
        Write-Host ''
        warn '即将卸载 Sub2API 容器'
        if (-not (confirm-prompt '确认停止并删除 Sub2API 容器和网络？' 'n')) {
            info '取消卸载'
            return
        }

        $deleteVolumes = confirm-prompt '是否永久删除 Sub2API、PostgreSQL 和 Redis 数据卷？' 'n'
        if ($deleteVolumes) {
            Invoke-Sub2ApiComposeAll down -v
            info 'Sub2API 容器、网络和数据卷已删除'
        } else {
            Invoke-Sub2ApiComposeAll down
            info 'Sub2API 容器和网络已删除，数据卷仍保留'
            warn '数据卷已保留'
        }

        if (confirm-prompt '是否删除包含密钥的 sub2api.env？' 'n') {
            Assert-RegularFile $script:SUB2API_ENV_FILE
            Remove-Item -LiteralPath $script:SUB2API_ENV_FILE -Force
            info 'sub2api.env 已删除'
        }
    } catch { error-msg $_.Exception.Message; exit 1 }
}

function show-sub2api-help {
    Write-Host ''
    Write-Host '  Sub2API companion stack'
    Write-Host '  .\deploy.ps1 sub2api [action]' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    deploy     生成密钥并一键部署（默认）' -ForegroundColor Cyan
    Write-Host '    init       只生成配置，便于先选择依赖模式' -ForegroundColor Cyan
    Write-Host '    start      启动或创建容器' -ForegroundColor Cyan
    Write-Host '    stop       停止容器并保留数据' -ForegroundColor Cyan
    Write-Host '    restart    重建并重启容器' -ForegroundColor Cyan
    Write-Host '    status     查看容器和健康状态' -ForegroundColor Cyan
    Write-Host '    logs [服务] 查看日志（默认 sub2api）' -ForegroundColor Cyan
    Write-Host '    update     拉取最新镜像并重建' -ForegroundColor Cyan
    Write-Host '    doctor     检查配置和暴露范围' -ForegroundColor Cyan
    Write-Host '    uninstall  卸载；数据和密钥分别确认' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  依赖模式在 sub2api.env 中分别设置:' -ForegroundColor DarkGray
    Write-Host '    SUB2API_POSTGRES_MODE=managed|external'
    Write-Host '    SUB2API_REDIS_MODE=managed|external'
    Write-Host ''
}

function cmd-sub2api {
    param(
        [Parameter(Position = 0)]
        [string]$action = 'deploy',

        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [string[]]$remaining = @()
    )
    if (-not $action) { $action = 'deploy' }
    switch ($action) {
        'deploy' { cmd-sub2api-deploy }
        'install' { cmd-sub2api-deploy }
        'init' { cmd-sub2api-init }
        'configure' { cmd-sub2api-init }
        'start' { cmd-sub2api-start }
        'stop' { cmd-sub2api-stop }
        'restart' { cmd-sub2api-restart }
        'status' { cmd-sub2api-status }
        'logs' {
            $service = if ($remaining.Count -gt 0) { $remaining[0] } else { 'sub2api' }
            cmd-sub2api-logs $service
        }
        'update' { cmd-sub2api-update }
        'doctor' { cmd-sub2api-doctor }
        'uninstall' { cmd-sub2api-uninstall }
        'help' { show-sub2api-help }
        '--help' { show-sub2api-help }
        '-h' { show-sub2api-help }
        default { error-msg "未知 Sub2API 操作: $action"; show-sub2api-help; exit 1 }
    }
}

# ========================== Cursor Bridge sidecar ============================

function Require-CursorBridgeCompose {
    try { $null = Get-Command docker -ErrorAction Stop }
    catch { throw '未检测到 Docker' }
    $null = docker info 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Docker 守护进程未运行' }
    $null = docker compose version 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Cursor Bridge 要求 Docker Compose v2' }
    $script:COMPOSE_CMD = 'docker compose'
    Assert-RegularFile $script:CURSOR_BRIDGE_COMPOSE_FILE
}

function Invoke-CursorBridgeCompose {
    $previousProject = $env:COMPOSE_PROJECT_NAME
    $env:COMPOSE_PROJECT_NAME = $script:CURSOR_BRIDGE_PROJECT_NAME
    try {
        Invoke-Compose -f $script:CURSOR_BRIDGE_COMPOSE_FILE @args
    } finally {
        if ($null -eq $previousProject) { Remove-Item Env:COMPOSE_PROJECT_NAME -ErrorAction SilentlyContinue }
        else { $env:COMPOSE_PROJECT_NAME = $previousProject }
    }
}

function Set-CursorBridgeEnvPermissions($path) {
    Set-Sub2ApiEnvPermissions $path
}

function Get-CursorBridgeEnvValue($key) {
    if (-not (Test-Path $script:CURSOR_BRIDGE_ENV_FILE -PathType Leaf)) { return '' }
    foreach ($line in Get-Content $script:CURSOR_BRIDGE_ENV_FILE) {
        if ($line -match "^$([regex]::Escape($key))=(.*)$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return ''
}

function Test-CursorBridgeEnvironment {
    Assert-RegularFile $script:CURSOR_BRIDGE_ENV_FILE
    $cursorKey = Get-CursorBridgeEnvValue 'CURSOR_API_KEY'
    $bridgeKey = Get-CursorBridgeEnvValue 'CURSOR_BRIDGE_API_KEY'
    if (-not $cursorKey -or $cursorKey.StartsWith('replace-locally-')) {
        throw '运行 .\deploy.ps1 cursor-bridge，按提示粘贴 Cursor API key'
    }
    if ($bridgeKey -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'CURSOR_BRIDGE_API_KEY 必须是 64 位 hex，请重跑 .\deploy.ps1 cursor-bridge init'
    }
    if ($cursorKey -eq $bridgeKey) { throw '两把 Cursor Bridge key 必须不同' }
    if ($script:CPA_API_KEY -and ($cursorKey -eq $script:CPA_API_KEY -or $bridgeKey -eq $script:CPA_API_KEY)) {
        throw '禁止复用 CPA_API_KEY'
    }
    if ($script:CPA_MANAGEMENT_KEY -and ($cursorKey -eq $script:CPA_MANAGEMENT_KEY -or $bridgeKey -eq $script:CPA_MANAGEMENT_KEY)) {
        throw '禁止复用 CPA_MANAGEMENT_KEY'
    }
    $raw = Get-Content $script:CURSOR_BRIDGE_ENV_FILE -Raw
    if ($raw -match '(?m)^\s*(CURSOR_CONFIG_DIRS|CURSOR_ACCOUNT_DIRS)=') {
        throw 'cursor-bridge.env 不能设 CURSOR_CONFIG_DIRS / CURSOR_ACCOUNT_DIRS'
    }
    Set-CursorBridgeEnvPermissions $script:CURSOR_BRIDGE_ENV_FILE
}

function New-CursorBridgeEnvironment {
    if (Test-Path $script:CURSOR_BRIDGE_ENV_FILE) {
        Assert-RegularFile $script:CURSOR_BRIDGE_ENV_FILE
        Set-CursorBridgeEnvPermissions $script:CURSOR_BRIDGE_ENV_FILE
        return
    }
    Assert-SafeRepoPath $script:CURSOR_BRIDGE_ENV_FILE $true
    Assert-RegularFile $script:CURSOR_BRIDGE_ENV_EXAMPLE_FILE
    $bridgeKey = New-CryptoHex 32
    $temp = Join-Path $script:SCRIPT_DIR ("cursor-bridge.env.tmp.{0}" -f [guid]::NewGuid().ToString('N'))
    (Get-Content $script:CURSOR_BRIDGE_ENV_EXAMPLE_FILE -Raw) -replace 'replace-locally-with-random-64-hex-key', $bridgeKey |
        Set-Content -Path $temp -Encoding utf8
    Set-CursorBridgeEnvPermissions $temp
    if (Test-Path $script:CURSOR_BRIDGE_ENV_FILE) {
        Remove-Item $temp -Force
        throw 'cursor-bridge.env 已被其他进程创建，请重试'
    }
    Move-Item $temp $script:CURSOR_BRIDGE_ENV_FILE
}

function Set-CursorBridgeEnvKey($name, $value) {
    Assert-RegularFile $script:CURSOR_BRIDGE_ENV_FILE
    $lines = @(Get-Content $script:CURSOR_BRIDGE_ENV_FILE)
    $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match "^$([regex]::Escape($name))=") {
            $found = $true
            "$name=$value"
        } else {
            $line
        }
    }
    if (-not $found) { $out += "$name=$value" }
    $temp = Join-Path $script:SCRIPT_DIR ("cursor-bridge.env.tmp.{0}" -f [guid]::NewGuid().ToString('N'))
    Set-Content -Path $temp -Value $out -Encoding utf8
    Set-CursorBridgeEnvPermissions $temp
    Move-Item -Force $temp $script:CURSOR_BRIDGE_ENV_FILE
    Set-CursorBridgeEnvPermissions $script:CURSOR_BRIDGE_ENV_FILE
}

function Read-HiddenCursorApiKey {
    if ([Console]::IsInputRedirected) {
        throw '需要交互输入 Cursor API key。在终端运行 .\deploy.ps1 cursor-bridge'
    }
    Write-Host ''
    Write-Host '  从 https://cursor.com/dashboard/api 创建 key，弹窗里复制完整值。输入时不显示。' -ForegroundColor DarkGray
    Write-Host '  ?  粘贴 Cursor API key: ' -ForegroundColor Magenta -NoNewline
    $secure = Read-Host -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function Request-CursorApiKey {
    param([switch]$Force)
    $current = Get-CursorBridgeEnvValue 'CURSOR_API_KEY'
    if (-not $Force -and $current -and -not $current.StartsWith('replace-locally-')) {
        if (-not (confirm-prompt '已保存一把 Cursor key，要更换吗？' 'n')) { return }
    }
    $key = (Read-HiddenCursorApiKey).Trim()
    if (-not $key) { throw 'key 不能为空' }
    if ($key.StartsWith('replace-locally-')) { throw '请粘贴真实的 Cursor key' }
    Set-CursorBridgeEnvKey 'CURSOR_API_KEY' $key
    info '已写入 CURSOR_API_KEY（不会打印）'
}

function Ensure-CursorBridgeReady {
    New-CursorBridgeEnvironment
    $bridgeKey = Get-CursorBridgeEnvValue 'CURSOR_BRIDGE_API_KEY'
    if ($bridgeKey -notmatch '^[A-Fa-f0-9]{64}$') {
        Set-CursorBridgeEnvKey 'CURSOR_BRIDGE_API_KEY' (New-CryptoHex 32)
        info '已自动生成 CURSOR_BRIDGE_API_KEY'
    }
    $cursorKey = Get-CursorBridgeEnvValue 'CURSOR_API_KEY'
    if (-not $cursorKey -or $cursorKey.StartsWith('replace-locally-')) {
        Request-CursorApiKey -Force
    }
    Test-CursorBridgeEnvironment
}

function Ensure-CursorBridgeImage {
    $null = docker image inspect $script:CURSOR_BRIDGE_IMAGE 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    step '构建钉死 Cursor Bridge 镜像'
    $context = "$($script:CURSOR_BRIDGE_SOURCE_REPOSITORY).git#$($script:CURSOR_BRIDGE_SOURCE_COMMIT)"
    $labels = @(
        "--label", "org.opencontainers.image.source=$($script:CURSOR_BRIDGE_SOURCE_REPOSITORY)",
        "--label", "org.opencontainers.image.revision=$($script:CURSOR_BRIDGE_SOURCE_COMMIT)",
        "-t", $script:CURSOR_BRIDGE_IMAGE,
        $context
    )
    $null = docker buildx version 2>$null
    if ($LASTEXITCODE -eq 0) {
        docker buildx build --load @labels
    } else {
        docker build @labels
    }
    if ($LASTEXITCODE -ne 0) { throw 'Cursor Bridge 镜像构建失败' }
}

function Connect-CursorBridgeCpa {
    $null = docker inspect $script:CONTAINER_NAME 2>$null
    if ($LASTEXITCODE -ne 0) {
        warn "$($script:CONTAINER_NAME) 未运行，先 .\deploy.ps1 start，再挂 Cursor Bridge 网"
        return
    }
    $networks = docker inspect $script:CONTAINER_NAME --format '{{json .NetworkSettings.Networks}}' 2>$null
    if ("$networks" -like "*$($script:CURSOR_BRIDGE_NETWORK)*") { return }
    docker network connect $script:CURSOR_BRIDGE_NETWORK $script:CONTAINER_NAME
    if ($LASTEXITCODE -ne 0) { throw "无法把 $($script:CONTAINER_NAME) 挂到 $($script:CURSOR_BRIDGE_NETWORK)" }
    info "已把 $($script:CONTAINER_NAME) 挂到 $($script:CURSOR_BRIDGE_NETWORK)"
}

function Ensure-CursorBridgeOpenaiCompatibility {
    if (-not (Test-Path $script:CONFIG_FILE -PathType Leaf)) {
        warn '没有 config.yaml，跳过 openai-compatibility'
        return $false
    }
    Assert-RegularFile $script:CONFIG_FILE
    $config = Get-Content $script:CONFIG_FILE -Raw
    if ($config -like '*http://cursor-bridge-guard:8080/v1*') {
        $backup = Join-Path $script:SCRIPT_DIR 'config.yaml.bak.cursor-bridge'
        if (-not (Test-Path $backup)) {
            Copy-Item $script:CONFIG_FILE $backup
            Set-CursorBridgeEnvPermissions $backup
        }
        $updated = $config.Replace('http://cursor-bridge-guard:8080/v1', 'http://cursor-bridge:8765/v1')
        Set-Content -Path $script:CONFIG_FILE -Value $updated.TrimEnd() -Encoding utf8
        Set-CursorBridgeEnvPermissions $script:CONFIG_FILE
        info '已把 cursor-bridge 上游改成直连 :8765'
        return $true
    }
    if ($config -match '(?m)^\s*-\s*name:\s*cursor-bridge\s*$') {
        info 'config.yaml 已有 cursor-bridge'
        return $false
    }
    $bridgeKey = Get-CursorBridgeEnvValue 'CURSOR_BRIDGE_API_KEY'
    if ($bridgeKey -notmatch '^[A-Fa-f0-9]{64}$') { return $false }
    $backup = Join-Path $script:SCRIPT_DIR 'config.yaml.bak.cursor-bridge'
    if (-not (Test-Path $backup)) {
        Copy-Item $script:CONFIG_FILE $backup
        Set-CursorBridgeEnvPermissions $backup
    }
    $item = @"

  - name: cursor-bridge
    prefix: cursor
    base-url: http://cursor-bridge:8765/v1
    api-key-entries:
      - api-key: "$bridgeKey"
    models:
      - name: auto
        alias: cursor-auto
"@
    if ($config -notmatch '(?m)^\s*openai-compatibility:') {
        $item = "`nopenai-compatibility:" + $item
    }
    Add-Content -Path $script:CONFIG_FILE -Value $item.TrimEnd() -Encoding utf8
    info '已写入 config.yaml 的 cursor-bridge 上游'
    return $true
}

function Start-CursorBridgeSidecarIfReady {
    if (-not (Test-Path $script:CURSOR_BRIDGE_ENV_FILE -PathType Leaf)) { return }
    try { Test-CursorBridgeEnvironment } catch {
        detail '发现 cursor-bridge.env 但还缺 Cursor key。在终端执行: .\deploy.ps1 cursor-bridge'
        return
    }
    info '检测到 cursor-bridge.env，同时启动 Cursor Bridge'
    try { cmd-cursor-bridge-start } catch { warn "Cursor Bridge 启动失败，CPA 已在运行。可单独执行 .\deploy.ps1 cursor-bridge start" }
}

function cmd-cursor-bridge-init {
    Require-CursorBridgeCompose
    New-CursorBridgeEnvironment
    $bridgeKey = Get-CursorBridgeEnvValue 'CURSOR_BRIDGE_API_KEY'
    if ($bridgeKey -notmatch '^[A-Fa-f0-9]{64}$') {
        Set-CursorBridgeEnvKey 'CURSOR_BRIDGE_API_KEY' (New-CryptoHex 32)
        info '已自动生成 CURSOR_BRIDGE_API_KEY'
    }
    Request-CursorApiKey
    Test-CursorBridgeEnvironment
    info 'Cursor Bridge 已初始化。接下来: .\deploy.ps1 cursor-bridge start'
}

function cmd-cursor-bridge-build {
    Require-CursorBridgeCompose
    Test-CursorBridgeEnvironment
    $null = docker image inspect $script:CURSOR_BRIDGE_IMAGE 2>$null
    if ($LASTEXITCODE -eq 0) { docker rmi $script:CURSOR_BRIDGE_IMAGE 2>$null }
    Ensure-CursorBridgeImage
    info "已构建 $($script:CURSOR_BRIDGE_IMAGE)"
}

function cmd-cursor-bridge-configure {
    Require-CursorBridgeCompose
    New-CursorBridgeEnvironment
    Request-CursorApiKey -Force
    Ensure-CursorBridgeReady
    $null = docker inspect $script:CURSOR_BRIDGE_CONTAINER_NAME 2>$null
    if ($LASTEXITCODE -eq 0) {
        Invoke-CursorBridgeCompose up -d --remove-orphans
        Connect-CursorBridgeCpa
        info '已更换 Cursor key 并重建桥容器'
    } else {
        info '已更换 Cursor key。接下来: .\deploy.ps1 cursor-bridge start'
    }
}

function cmd-cursor-bridge-start {
    Require-CursorBridgeCompose
    Ensure-CursorBridgeReady
    Ensure-CursorBridgeImage
    Invoke-CursorBridgeCompose config --quiet
    Invoke-CursorBridgeCompose up -d --remove-orphans
    $null = docker network rm cursor-bridge-backend 2>$null
    Connect-CursorBridgeCpa
    $appended = Ensure-CursorBridgeOpenaiCompatibility
    if ($appended) {
        info '正在重启 CPA，让它读到 Cursor 上游（约几秒）'
        try { cmd-restart } catch { warn 'CPA 重启失败，请稍后执行 .\deploy.ps1 restart' }
    }
    info 'Cursor Bridge 已启动。CPA 直连 :8765，无主机端口'
    info 'CPA 面板不会自己拉模型。同步列表: .\deploy.ps1 cursor-bridge sync-models'
}

function cmd-cursor-bridge-stop {
    Require-CursorBridgeCompose
    Invoke-CursorBridgeCompose stop
    info 'Cursor Bridge 已停止（未动 CPA）'
}

function cmd-cursor-bridge-restart {
    Require-CursorBridgeCompose
    Test-CursorBridgeEnvironment
    Invoke-CursorBridgeCompose restart
    Connect-CursorBridgeCpa
    info 'Cursor Bridge 已重启'
}

function cmd-cursor-bridge-status {
    Require-CursorBridgeCompose
    Invoke-CursorBridgeCompose ps
    $null = docker inspect $script:CONTAINER_NAME 2>$null
    if ($LASTEXITCODE -eq 0) {
        $networks = docker inspect $script:CONTAINER_NAME --format '{{json .NetworkSettings.Networks}}' 2>$null
        if ("$networks" -like "*$($script:CURSOR_BRIDGE_NETWORK)*") {
            info "$($script:CONTAINER_NAME) 已在 $($script:CURSOR_BRIDGE_NETWORK)"
        } else {
            warn "$($script:CONTAINER_NAME) 还没挂 $($script:CURSOR_BRIDGE_NETWORK)"
        }
    }
}

function cmd-cursor-bridge-logs($service = '') {
    Require-CursorBridgeCompose
    if ($service) { Invoke-CursorBridgeCompose logs -f --tail 200 $service }
    else { Invoke-CursorBridgeCompose logs -f --tail 200 }
}

function cmd-cursor-bridge-doctor {
    Require-CursorBridgeCompose
    Test-CursorBridgeEnvironment
    Invoke-CursorBridgeCompose config --quiet
    $null = docker image inspect $script:CURSOR_BRIDGE_IMAGE 2>$null
    if ($LASTEXITCODE -ne 0) { throw "缺少钉死镜像 $($script:CURSOR_BRIDGE_IMAGE)" }
    $user = docker inspect $script:CURSOR_BRIDGE_CONTAINER_NAME --format '{{.Config.User}}' 2>$null
    if ($user -ne 'app') { throw 'cursor-bridge 必须以 user=app 运行' }
    $ports = "$(docker port $script:CURSOR_BRIDGE_CONTAINER_NAME 2>$null)"
    if ($ports -like '*0.0.0.0:*') { throw '桥端口绑到了 0.0.0.0' }
    $null = docker inspect $script:CONTAINER_NAME 2>$null
    if ($LASTEXITCODE -eq 0) {
        $networks = docker inspect $script:CONTAINER_NAME --format '{{json .NetworkSettings.Networks}}' 2>$null
        if ("$networks" -notlike "*$($script:CURSOR_BRIDGE_NETWORK)*") {
            throw "CPA 未挂 $($script:CURSOR_BRIDGE_NETWORK)"
        }
    }
    $cursorKey = Get-CursorBridgeEnvValue 'CURSOR_API_KEY'
    $bridgeKey = Get-CursorBridgeEnvValue 'CURSOR_BRIDGE_API_KEY'
    $logs = "$(docker logs $script:CURSOR_BRIDGE_CONTAINER_NAME 2>&1)"
    if (($cursorKey -and $logs.Contains($cursorKey)) -or ($bridgeKey -and $logs.Contains($bridgeKey))) {
        throw '日志里出现了 key'
    }
    info 'Cursor Bridge doctor PASS'
    cmd-cursor-bridge-status
}

function cmd-cursor-bridge-sync-models {
    param([string]$only = '')
    Require-CursorBridgeCompose
    Test-CursorBridgeEnvironment
    Assert-RegularFile $script:CONFIG_FILE
    $config = Get-Content $script:CONFIG_FILE -Raw
    if ($config -notmatch '(?m)^\s*-\s*name:\s*cursor-bridge\s*$') {
        throw 'config.yaml 还没有 cursor-bridge。先 .\deploy.ps1 cursor-bridge'
    }
    $null = docker inspect $script:CURSOR_BRIDGE_CONTAINER_NAME 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'cursor-bridge 未运行，先 .\deploy.ps1 cursor-bridge' }
    $jsonText = docker exec $script:CURSOR_BRIDGE_CONTAINER_NAME sh -c 'curl -sS -H "Authorization: Bearer ${CURSOR_BRIDGE_API_KEY}" http://127.0.0.1:8765/v1/models'
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jsonText)) { throw '无法从桥拉取 /v1/models' }
    $payload = $jsonText | ConvertFrom-Json
    if (-not ($payload.PSObject.Properties.Name -contains 'data')) { throw '桥返回的不是模型列表' }
    $allow = @()
    if ($only) { $allow = @($only.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $ids = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in @($payload.data)) {
        $mid = [string]$item.id
        if ($mid -notmatch '^[A-Za-z0-9._:-]+$') { continue }
        if ($allow.Count -gt 0 -and $allow -notcontains $mid) { continue }
        if ($seen.ContainsKey($mid)) { continue }
        $seen[$mid] = $true
        [void]$ids.Add($mid)
    }
    $rest = @($ids | Where-Object { $_ -ne 'auto' })
    $ordered = @('auto') + $rest
    $block = New-Object System.Collections.Generic.List[string]
    [void]$block.Add('    models:')
    foreach ($mid in $ordered) {
        $alias = if ($mid -eq 'auto') { 'cursor-auto' } else { $mid }
        [void]$block.Add("      - name: $mid")
        [void]$block.Add("        alias: $alias")
    }
    $src = Get-Content $script:CONFIG_FILE
    $out = New-Object System.Collections.Generic.List[string]
    $found = $false
    $i = 0
    while ($i -lt $src.Count) {
        $line = $src[$i]
        if ($line -match '^\s*-\s*name:\s*cursor-bridge\s*$') {
            $found = $true
            [void]$out.Add($line)
            $i++
            $inserted = $false
            while ($i -lt $src.Count) {
                $nxt = $src[$i]
                if ($nxt -match '^\s*models:\s*$') {
                    $i++
                    while ($i -lt $src.Count -and ($src[$i].StartsWith('      ') -or [string]::IsNullOrWhiteSpace($src[$i]))) { $i++ }
                    foreach ($row in $block) { [void]$out.Add($row) }
                    $inserted = $true
                    break
                }
                if ($nxt -match '^  - ' -or $nxt -match '^[A-Za-z]') {
                    foreach ($row in $block) { [void]$out.Add($row) }
                    $inserted = $true
                    break
                }
                [void]$out.Add($nxt)
                $i++
            }
            if (-not $inserted) { foreach ($row in $block) { [void]$out.Add($row) } }
            continue
        }
        [void]$out.Add($line)
        $i++
    }
    if (-not $found) { throw 'config.yaml 里没有 cursor-bridge 段' }
    $backup = Join-Path $script:SCRIPT_DIR 'config.yaml.bak.cursor-bridge'
    if (-not (Test-Path $backup)) {
        Copy-Item $script:CONFIG_FILE $backup
        Set-CursorBridgeEnvPermissions $backup
    }
    Set-Content -Path $script:CONFIG_FILE -Value $out -Encoding utf8
    Set-CursorBridgeEnvPermissions $script:CONFIG_FILE
    info "已把桥上 $($ordered.Count) 个模型写入 config.yaml（auto 仍叫 cursor-auto）"
    info '正在重启 CPA，让面板读到新列表（约几秒）'
    try { cmd-restart } catch { warn 'CPA 重启失败，请稍后执行 .\deploy.ps1 restart' }
}

function cmd-cursor-bridge-uninstall {
    Require-CursorBridgeCompose
    $null = docker inspect $script:CONTAINER_NAME 2>$null
    if ($LASTEXITCODE -eq 0) {
        docker network disconnect $script:CURSOR_BRIDGE_NETWORK $script:CONTAINER_NAME 2>$null
    }
    Invoke-CursorBridgeCompose down --remove-orphans
    info 'Cursor Bridge 已卸载（未删 CPA 卷）'
    detail '若已追加 openai-compatibility，请从 config.yaml 删掉 cursor-bridge 段后 .\deploy.ps1 restart'
    if ((Test-Path $script:CURSOR_BRIDGE_ENV_FILE -PathType Leaf) -and (confirm-prompt '是否删除包含密钥的 cursor-bridge.env？' 'n')) {
        Assert-RegularFile $script:CURSOR_BRIDGE_ENV_FILE
        Remove-Item $script:CURSOR_BRIDGE_ENV_FILE -Force
        info 'cursor-bridge.env 已删除'
    }
}

function show-cursor-bridge-help {
    Write-Host ''
    Write-Host '  Cursor Bridge sidecar'
    Write-Host '  .\deploy.ps1 cursor-bridge [action]' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    start      缺 key 就提示输入，然后构建并启动（默认）' -ForegroundColor Cyan
    Write-Host '    init       生成 env，提示输入一把 Cursor key' -ForegroundColor Cyan
    Write-Host '    configure  更换 Cursor key，并重建桥容器' -ForegroundColor Cyan
    Write-Host '    stop       停止桥，不动 CPA' -ForegroundColor Cyan
    Write-Host '    restart    重启桥容器' -ForegroundColor Cyan
    Write-Host '    status     查看桥和挂网状态' -ForegroundColor Cyan
    Write-Host '    logs [服务] 查看日志' -ForegroundColor Cyan
    Write-Host '    build      重新构建钉死镜像' -ForegroundColor Cyan
    Write-Host '    doctor     检查钉死、端口、挂网、401' -ForegroundColor Cyan
    Write-Host '    sync-models 从桥 /v1/models 写入 config.yaml（可跟 id 列表）' -ForegroundColor Cyan
    Write-Host '    uninstall  拆桥；不删 CPA 卷' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  默认向导不会安装这座桥。执行 .\deploy.ps1 cursor-bridge，按提示粘贴一把 Cursor key。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  把桥上的模型写进 config.yaml:'
    Write-Host '    CPA 面板不会自己拉 /v1/models。默认只有 cursor-auto。' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1 cursor-bridge sync-models'
    Write-Host '    # 只要几个模型' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1 cursor-bridge sync-models auto,cursor-grok-4.6'
    Write-Host '    脚本在桥容器里用已有 key 拉列表，只改 cursor-bridge 的 models:，然后重启 CPA。' -ForegroundColor DarkGray
    Write-Host '    auto 的别名仍是 cursor-auto；其它 id 原样当 alias。客户端继续用 CPA_API_KEY。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  套餐额度：桥 HTTP 没有 /usage。chat 里的 usage 只是估算，不是 Cursor 账单。看额度请打开 cursor.com/dashboard。' -ForegroundColor DarkGray
    Write-Host ''
}

function cmd-cursor-bridge {
    param(
        [Parameter(Position = 0)]
        [string]$action = 'start',
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$remaining = @()
    )
    switch ($action) {
        'start' { cmd-cursor-bridge-start }
        'deploy' { cmd-cursor-bridge-start }
        'init' { cmd-cursor-bridge-init }
        'configure' { cmd-cursor-bridge-configure }
        'build' { cmd-cursor-bridge-build }
        'stop' { cmd-cursor-bridge-stop }
        'restart' { cmd-cursor-bridge-restart }
        'status' { cmd-cursor-bridge-status }
        'logs' {
            $service = if ($remaining.Count -gt 0) { $remaining[0] } else { '' }
            cmd-cursor-bridge-logs $service
        }
        'doctor' { cmd-cursor-bridge-doctor }
        'sync-models' {
            $only = if ($remaining.Count -gt 0) { $remaining[0] } else { '' }
            cmd-cursor-bridge-sync-models $only
        }
        'sync' {
            $only = if ($remaining.Count -gt 0) { $remaining[0] } else { '' }
            cmd-cursor-bridge-sync-models $only
        }
        'uninstall' { cmd-cursor-bridge-uninstall }
        'help' { show-cursor-bridge-help }
        '--help' { show-cursor-bridge-help }
        '-h' { show-cursor-bridge-help }
        default { error-msg "未知 Cursor Bridge 操作: $action"; show-cursor-bridge-help; exit 1 }
    }
}

# ========================== 帮助信息 ==========================================

function show-help {
    Write-Host ''
    Write-Host "  CLI Proxy Manager v$script:VERSION"
    Write-Host '  一键部署和管理 CLIProxyAPI' -ForegroundColor DarkGray
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
    Write-Host '    capabilities [--json] 只读 CPA 能力和暴露检查' -ForegroundColor Cyan
    Write-Host '    doctor       Doctor v2 只读诊断' -ForegroundColor Cyan
    Write-Host '    backup [文件] 备份配置和 OAuth 凭证' -ForegroundColor Cyan
    Write-Host '    restore <文件> 恢复配置和 OAuth 凭证' -ForegroundColor Cyan
    Write-Host '    check-update  只检查镜像是否有更新' -ForegroundColor Cyan
    Write-Host '    update       更新、健康检查，失败时自动回滚' -ForegroundColor Cyan
    Write-Host '    rollback     手动切换到上一个镜像版本' -ForegroundColor Cyan
    Write-Host '    uninstall    完全卸载' -ForegroundColor Cyan
    Write-Host '    setup-claude 自动配置 Claude Code 环境' -ForegroundColor Cyan
    Write-Host '    sub2api [操作] 管理独立的 Sub2API 一键部署' -ForegroundColor Cyan
    Write-Host '    cursor-bridge [操作] 管理可选 Cursor Bridge sidecar' -ForegroundColor Cyan
    Write-Host '    help         显示此帮助' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  环境变量:'
    Write-Host '    CPA_PORT     服务端口 (默认: 8317)' -ForegroundColor Cyan
    Write-Host '    CPA_API_KEY  API 密钥' -ForegroundColor Cyan
    Write-Host '    CPA_EXPOSURE_MODE 可选: public-proxy (仅用于能力分类)' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  示例:'
    Write-Host '    # 完整部署' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1'
    Write-Host ''
    Write-Host '    # 使用自定义端口' -ForegroundColor DarkGray
    Write-Host '    $env:CPA_PORT=9000; .\deploy.ps1 start'
    Write-Host ''
    Write-Host '    # 自检并备份' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1 capabilities --json'
    Write-Host '    .\deploy.ps1 doctor'
    Write-Host '    .\deploy.ps1 backup'
    Write-Host ''
    Write-Host '    # 一键部署独立 Sub2API 栈' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1 sub2api deploy'
    Write-Host ''
    Write-Host '    # 一键部署可选 Cursor Bridge sidecar（会提示输入一把 Cursor key）' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1 cursor-bridge'
    Write-Host '    # 把桥上的模型列表写入 config.yaml（CPA 面板不会自己拉）' -ForegroundColor DarkGray
    Write-Host '    .\deploy.ps1 cursor-bridge sync-models'
    Write-Host ''
}

# ========================== 入口 ==============================================

function Import-ProjectEnvironment {
    $envFile = Join-Path $script:SCRIPT_DIR '.env'
    if (Test-Path $envFile -PathType Leaf) {
        Get-Content $envFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#')) {
                $parts = $line -split '=', 2
                if ($parts.Length -eq 2) {
                    $key = $parts[0].Trim(); $val = $parts[1].Trim().Trim('"').Trim("'")
                    Set-Item -Path "env:$key" -Value $val
                    switch ($key) {
                        'CPA_PORT'           { $script:CPA_PORT = $val }
                        'CPA_API_KEY'        { $script:CPA_API_KEY = $val }
                        'CPA_MANAGEMENT_KEY' { $script:CPA_MANAGEMENT_KEY = $val }
                        'CPA_IMAGE'          { $script:DOCKER_IMAGE = $val }
                    }
                }
            }
        }
    }
}

function main {
    Import-ProjectEnvironment
    $command = if ($args.Count -gt 0) { $args[0] } else { '' }

    switch ($command) {
        'login'     { cmd-login @args }
        'logout'    { cmd-logout }
        'start'     { cmd-start @args }
        'stop'      { cmd-stop @args }
        'restart'   { cmd-restart @args }
        'status'    { cmd-status @args }
        'logs'      { cmd-logs @args }
        'capabilities' {
            [string[]]$capabilityOptions = @()
            if ($args.Count -gt 1) { $capabilityOptions = @($args[1..($args.Count - 1)]) }
            cmd-capabilities -Options $capabilityOptions
        }
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
        'rollback'  { cmd-rollback }
        'uninstall' { cmd-uninstall @args }
        'setup-claude' { cmd-setup-claude }
        'sub2api' {
            [string[]]$sub2apiArgs = @()
            if ($args.Count -gt 1) { $sub2apiArgs = @($args[1..($args.Count - 1)]) }
            cmd-sub2api @sub2apiArgs
        }
        'cursor-bridge' {
            [string[]]$cursorBridgeArgs = @()
            if ($args.Count -gt 1) { $cursorBridgeArgs = @($args[1..($args.Count - 1)]) }
            cmd-cursor-bridge @cursorBridgeArgs
        }
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
