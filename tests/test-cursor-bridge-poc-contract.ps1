$ErrorActionPreference = 'Stop'

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PocDir = Join-Path $RootDir 'poc/cursor-bridge'
$ComposeFile = Join-Path $PocDir 'docker-compose.yml'
$EnvExample = Join-Path $PocDir 'poc.env.example'
$PocSh = Join-Path $PocDir 'poc.sh'
$PocPs1 = Join-Path $PocDir 'poc.ps1'
$SourceCommit = 'c0ff1f941215027c0a8f658ca5d01f806559208f'

function Fail([string]$Message) {
    throw "FAIL: $Message"
}

function Assert-Contains([string]$Path, [string]$Needle, [string]$Message) {
    if (-not (Select-String -LiteralPath $Path -SimpleMatch -Quiet -Pattern $Needle)) {
        Fail $Message
    }
}

function Assert-NotContains([string]$Path, [string]$Needle, [string]$Message) {
    if (Select-String -LiteralPath $Path -SimpleMatch -Quiet -Pattern $Needle) {
        Fail $Message
    }
}

function Assert-TextContains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) { Fail $Message }
}

function Assert-TextNotContains([string]$Text, [string]$Needle, [string]$Message) {
    if ($Text.Contains($Needle)) { Fail $Message }
}

function Get-PocPowerShellFunction([string]$Name) {
    $content = Get-Content -LiteralPath $PocPs1 -Raw
    $match = [regex]::Match($content, "(?mis)^\s*function\s+$Name\b.*?(?=^\s*function\s+|\z)")
    if (-not $match.Success) { return $null }
    return $match.Value
}

function Get-PocBashFunction([string]$Name) {
    $content = Get-Content -LiteralPath $PocSh -Raw
    $match = [regex]::Match($content, "(?ms)^\s*$Name\s*\(\).*?(?=^\s*[A-Za-z_][A-Za-z0-9_]*\s*\(\)|\z)")
    if (-not $match.Success) { return $null }
    return $match.Value
}

function Get-CursorBridgeService {
    $active = $false
    $lines = foreach ($line in Get-Content -LiteralPath $ComposeFile) {
        if ($line -match '^\s*services:\s*$') { continue }
        if ($line -match '^\s{2}cursor-bridge:\s*$') { $active = $true; continue }
        if ($active -and $line -match '^\s{2}[A-Za-z0-9_-]+:\s*$') { break }
        if ($active) { ($line -replace '\s*#.*$', '') }
    }
    return ($lines -join "`n").Trim()
}

function Get-EffectiveEnv {
    return ((Get-Content -LiteralPath $EnvExample | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' } | ForEach-Object { $_ -replace '\s*#.*$', '' }) -join "`n")
}

function Assert-ReadOnlyDockerBody([string]$Body, [string]$Label) {
    if ($Body -match '(?i)(^|[^\w-])(docker\s+compose|docker-compose|compose)(\s|$)') {
        Fail "$Label must not invoke Compose"
    }
    foreach ($match in [regex]::Matches($Body, '(?i)(?:^|[^\w-])docker\s+([^\s;|]+)')) {
        if ($match.Groups[1].Value.ToLowerInvariant() -notin @('port', 'logs', 'inspect')) {
            Fail "$Label may only use docker port, docker logs, or docker inspect"
        }
    }
}

function Assert-PowerShellDoctorReachability([string]$FunctionName, [hashtable]$Visited) {
    if ($Visited.ContainsKey($FunctionName)) { return }
    $Visited[$FunctionName] = $true
    $Body = Get-PocPowerShellFunction $FunctionName
    if ([string]::IsNullOrWhiteSpace($Body)) { Fail "poc.ps1 doctor helper $FunctionName must exist" }
    $Body = (($Body -split "`r?`n" | ForEach-Object { $_ -replace '\s*#.*$', '' }) -join "`n")
    if ($Body -match '(?i)\bInvoke-PocCompose\b') { Fail "poc.ps1 doctor helper $FunctionName must not invoke Invoke-PocCompose" }
    Assert-ReadOnlyDockerBody $Body "poc.ps1 doctor helper $FunctionName"
    foreach ($Match in [regex]::Matches($PocPs1Content, '(?mi)^\s*function\s+([A-Za-z][A-Za-z0-9-]*)\b')) {
        $Helper = $Match.Groups[1].Value
        if ($Helper -ne $FunctionName -and $Body -match "(?i)(^|[^\w-])$([regex]::Escape($Helper))(\s|\(|$)") {
            Assert-PowerShellDoctorReachability $Helper $Visited
        }
    }
}

function Assert-BashDoctorReachability([string]$FunctionName, [hashtable]$Visited) {
    if ($Visited.ContainsKey($FunctionName)) { return }
    $Visited[$FunctionName] = $true
    $Body = Get-PocBashFunction $FunctionName
    if ([string]::IsNullOrWhiteSpace($Body)) { Fail "poc.sh doctor helper $FunctionName must exist" }
    $Body = (($Body -split "`r?`n" | ForEach-Object { $_ -replace '\s*#.*$', '' }) -join "`n")
    Assert-ReadOnlyDockerBody $Body "poc.sh doctor helper $FunctionName"
    foreach ($Match in [regex]::Matches($PocShContent, '(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)')) {
        $Helper = $Match.Groups[1].Value
        if ($Helper -ne $FunctionName -and $Body -match "(^|[^\w-])$([regex]::Escape($Helper))(\s|\(|$)") {
            Assert-BashDoctorReachability $Helper $Visited
        }
    }
}

foreach ($RequiredFile in @($ComposeFile, $EnvExample, $PocSh, $PocPs1)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        Fail "Missing required POC file: $RequiredFile"
    }
}

$ComposeService = Get-CursorBridgeService
if ([string]::IsNullOrWhiteSpace($ComposeService)) { Fail 'Compose must define a cursor-bridge service' }
$EffectiveEnv = Get-EffectiveEnv

Assert-Contains $PocSh $SourceCommit "poc.sh must pin source commit $SourceCommit"
Assert-Contains $PocPs1 $SourceCommit "poc.ps1 must pin source commit $SourceCommit"
$Port8765Mappings = @(
    foreach ($Line in ($ComposeService -split "`n")) {
        $Mapping = $Line.Trim()
        if ($Mapping.StartsWith('-')) {
            $Mapping = $Mapping.Substring(1).Trim()
            $Mapping = $Mapping -replace '\s+#.*$', ''
            if (($Mapping.StartsWith('"') -and $Mapping.EndsWith('"')) -or ($Mapping.StartsWith("'") -and $Mapping.EndsWith("'"))) {
                $Mapping = $Mapping.Substring(1, $Mapping.Length - 2)
            }
            if ($Mapping -match ':8765(?:/(?:tcp|udp))?\s*$') { $Mapping }
        }
    }
)
if ($Port8765Mappings.Count -ne 1) {
    Fail 'Compose must define exactly one short-syntax mapping for container port 8765'
}
$ExpectedLoopbackMapping = '127.0.0.1:${CURSOR_BRIDGE_POC_PORT:-18765}:8765'
if ($Port8765Mappings[0] -ne $ExpectedLoopbackMapping) {
    Fail 'Compose must bind container port 8765 with the exact loopback mapping'
}
if ($ComposeService -match '(?m)^\s*(?:-\s*)?target:\s*["'']?8765["'']?(\s|#|$)') {
    Fail 'Compose must not use long-syntax target: 8765 port mappings'
}
Assert-TextNotContains $ComposeService '0.0.0.0:' 'Compose must not expose the POC on all IPv4 interfaces'
Assert-TextNotContains $ComposeService ':::' 'Compose must not expose the POC on all IPv6 interfaces'
Assert-TextContains $ComposeService 'pull_policy: never' 'Compose must never pull an unpinned image'
$ImageLines = @($ComposeService -split "`n" | Where-Object { $_ -match '^\s*image:\s*\S+' })
if ($ImageLines.Count -ne 1) { Fail 'Compose must define exactly one cursor-bridge image' }
$ImageRef = ($ImageLines[0] -replace '^\s*image:\s*', '').Trim().Trim('"', "'")
$ImageBaseName = ($ImageRef -split '/')[-1]
if ($ImageRef -notmatch '@sha256:' -and $ImageBaseName -notmatch ':.+') { Fail 'Compose image must use an explicit immutable tag or digest' }
if ($ImageRef -match ':latest$') { Fail 'Compose image must not use the mutable latest tag' }
$EnvImageLines = @($EffectiveEnv -split "`n" | Where-Object { $_ -match '^\s*CURSOR_BRIDGE_IMAGE=' })
if ($EnvImageLines.Count -gt 0) {
    if ($EnvImageLines.Count -ne 1) { Fail 'Environment example must not define duplicate CURSOR_BRIDGE_IMAGE values' }
    $EnvImageRef = ($EnvImageLines[0] -split '=', 2)[1].Trim().Trim('"', "'")
    $EnvImageBaseName = ($EnvImageRef -split '/')[-1]
    if ($EnvImageRef -notmatch '@sha256:' -and $EnvImageBaseName -notmatch ':.+') { Fail 'CURSOR_BRIDGE_IMAGE must use an explicit tag or digest' }
    if ($EnvImageRef -match ':latest$') { Fail 'CURSOR_BRIDGE_IMAGE must not use the mutable latest tag' }
}

Assert-TextContains $ComposeService 'cap_drop:' 'Compose must drop Linux capabilities'
Assert-TextContains $ComposeService '      - ALL' 'Compose must drop all Linux capabilities'
Assert-TextContains $ComposeService 'no-new-privileges:true' 'Compose must enable no-new-privileges'
Assert-TextContains $ComposeService 'pids_limit: 128' 'Compose must limit PIDs'
Assert-TextContains $ComposeService 'mem_limit: 2g' 'Compose must limit memory'
Assert-TextContains $ComposeService 'cpus: "2.0"' 'Compose must limit CPU'
foreach ($ForbiddenMount in @('/var/run/docker.sock', '/run/docker.sock', '/root/.cli-proxy-api', 'cli-proxy-manager-auth', '../config.yaml', './config.yaml', '/config.yaml')) {
    Assert-TextNotContains $ComposeService $ForbiddenMount "Compose must not mount live Docker or CPA configuration: $ForbiddenMount"
}

foreach ($Setting in @('CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true', 'CURSOR_BRIDGE_MODE=ask', 'CURSOR_BRIDGE_FORCE=false', 'CURSOR_BRIDGE_APPROVE_MCPS=false', 'CURSOR_BRIDGE_VERBOSE=false', 'CURSOR_BRIDGE_MAX_MODE=false', 'CURSOR_BRIDGE_USE_ACP=true', 'CURSOR_BRIDGE_ACP_RAW_DEBUG=false', 'CURSOR_BRIDGE_MULTI_PORT=false')) {
    $Name, $Value = $Setting -split '=', 2
    $Assignments = @($EffectiveEnv -split "`n" | Where-Object { $_ -match "^\s*$Name=" })
    if ($Assignments.Count -ne 1 -or $Assignments[0].Trim() -ne "$Name=$Value") {
        Fail "Environment example must define exactly one safe $Setting"
    }
}
Assert-TextNotContains $EffectiveEnv 'CURSOR_CONFIG_DIRS=' 'Environment example must not define CURSOR_CONFIG_DIRS'
Assert-TextNotContains $EffectiveEnv 'CURSOR_ACCOUNT_DIRS=' 'Environment example must not define CURSOR_ACCOUNT_DIRS'

foreach ($Command in @('init', 'build', 'start', 'status', 'doctor', 'smoke', 'logs', 'stop', 'destroy')) {
    if (-not (Select-String -LiteralPath $PocSh -Quiet -Pattern "(?m)^\s*$Command\)\s*cmd_$Command\s*;;")) {
        Fail "poc.sh must dispatch $Command to cmd_$Command"
    }
    if ([string]::IsNullOrWhiteSpace((Get-PocBashFunction "cmd_$Command"))) {
        Fail "poc.sh must define cmd_$Command()"
    }
    $PowerShellCommand = $Command.Substring(0, 1).ToUpperInvariant() + $Command.Substring(1)
    $SwitchPattern = '(?m)^\s*[\x27\x22]' + [regex]::Escape($Command) + '[\x27\x22]\s*\{\s*' + [regex]::Escape("Invoke-Poc$PowerShellCommand") + '\s*\}'
    if (-not (Select-String -LiteralPath $PocPs1 -Quiet -Pattern $SwitchPattern)) {
        Fail "poc.ps1 must dispatch $Command to Invoke-Poc$PowerShellCommand"
    }
    if ([string]::IsNullOrWhiteSpace((Get-PocPowerShellFunction "Invoke-Poc$PowerShellCommand"))) {
        Fail "poc.ps1 must define Invoke-Poc$PowerShellCommand"
    }
}

$BashBuildBlock = Get-PocBashFunction 'cmd_build'
Assert-TextContains $BashBuildBlock 'SOURCE_COMMIT' 'poc.sh build must use SOURCE_COMMIT'
if ($BashBuildBlock -notmatch '(?is)git\s+.*(checkout|reset)\s+.*(SOURCE_COMMIT|c0ff1f941215027c0a8f658ca5d01f806559208f)') {
    Fail 'poc.sh build must check out the pinned source commit'
}
$PowerShellBuildBlock = Get-PocPowerShellFunction 'Invoke-PocBuild'
Assert-TextContains $PowerShellBuildBlock 'SourceCommit' 'poc.ps1 build must use SourceCommit'
if ($PowerShellBuildBlock -notmatch '(?is)git\s+.*(checkout|reset)\s+.*(SourceCommit|c0ff1f941215027c0a8f658ca5d01f806559208f)') {
    Fail 'poc.ps1 build must check out the pinned source commit'
}

$PocShContent = Get-Content -LiteralPath $PocSh -Raw
$BashDoctorStart = [regex]::Match($PocShContent, '(?m)^\s*cmd_doctor\(\)')
$BashSmokeBoundary = [regex]::Match($PocShContent, '(?m)^\s*cmd_smoke\(\)')
if (-not $BashDoctorStart.Success -or -not $BashSmokeBoundary.Success -or $BashSmokeBoundary.Index -le $BashDoctorStart.Index) {
    Fail 'poc.sh must define cmd_doctor() before cmd_smoke()'
}
$BashDoctorMatch = [regex]::Match($PocShContent, '(?ms)^\s*cmd_doctor\(\).*?(?=^\s*cmd_smoke\(\))')
Assert-ReadOnlyDockerBody $BashDoctorMatch.Value 'poc.sh doctor'
Assert-BashDoctorReachability 'cmd_doctor' @{}

$PocPs1Content = Get-Content -LiteralPath $PocPs1 -Raw
$PowerShellDoctorStart = [regex]::Match($PocPs1Content, '(?mi)^\s*function\s+Invoke-PocDoctor\b')
$PowerShellSmokeBoundary = [regex]::Match($PocPs1Content, '(?mi)^\s*function\s+Invoke-PocSmoke\b')
if (-not $PowerShellDoctorStart.Success -or -not $PowerShellSmokeBoundary.Success -or $PowerShellSmokeBoundary.Index -le $PowerShellDoctorStart.Index) {
    Fail 'poc.ps1 must define Invoke-PocDoctor before Invoke-PocSmoke'
}
$PowerShellDoctorMatch = [regex]::Match($PocPs1Content, '(?mis)^\s*function\s+Invoke-PocDoctor\b.*?(?=^\s*function\s+Invoke-PocSmoke\b)')
if ($PowerShellDoctorMatch.Value -match '(?i)\bInvoke-PocCompose\b') { Fail 'poc.ps1 doctor must not invoke Invoke-PocCompose' }
Assert-ReadOnlyDockerBody $PowerShellDoctorMatch.Value 'poc.ps1 doctor'
Assert-PowerShellDoctorReachability 'Invoke-PocDoctor' @{}

$BashDestroyBlock = Get-PocBashFunction 'cmd_destroy'
Assert-TextContains $BashDestroyBlock 'compose down --remove-orphans' 'poc.sh destroy must remove only POC Compose resources'
if ($BashDestroyBlock -match '(?i)(docker\s+|rm\s+-rf|--volumes|volume|system|network)') { Fail 'poc.sh destroy must not delete broader Docker or filesystem resources' }
$PowerShellDestroyBlock = Get-PocPowerShellFunction 'Invoke-PocDestroy'
Assert-TextContains $PowerShellDestroyBlock "Invoke-PocCompose @('down','--remove-orphans')" 'poc.ps1 destroy must remove only POC Compose resources'
if ($PowerShellDestroyBlock -match '(?i)(docker\s+|Remove-Item|--volumes|volume|system|network)') { Fail 'poc.ps1 destroy must not delete broader Docker or filesystem resources' }

Write-Output 'PASS: PowerShell Cursor Bridge POC contract matches the Bash contract'
