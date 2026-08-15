$ErrorActionPreference = 'Stop'

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PocDir = Join-Path $RootDir 'poc/cursor-bridge'
$ComposeFile = Join-Path $PocDir 'docker-compose.yml'
$EnvExample = Join-Path $PocDir 'poc.env.example'
$PocSh = Join-Path $PocDir 'poc.sh'
$PocPs1 = Join-Path $PocDir 'poc.ps1'
$SourceCommit = 'c0ff1f941215027c0a8f658ca5d01f806559208f'
$SourceRepository = 'https://github.com/anyrobert/cursor-api-proxy'
$ExpectedImage = "cursor-api-proxy:poc-$SourceCommit"
$ExpectedPortLine = '127.0.0.1:${CURSOR_BRIDGE_POC_PORT:-18765}:8765'
$ProjectName = 'cursor-bridge-poc'
$Commands = @('init', 'build', 'start', 'status', 'doctor', 'smoke', 'logs', 'stop', 'destroy')

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

function Get-PocPowerShellFunction([string]$Name) {
    $content = Get-Content -LiteralPath $PocPs1 -Raw
    $match = [regex]::Match($content, "(?mis)^\s*function\s+$Name\b.*?(?=^\s*function\s+|\z)")
    if (-not $match.Success) { return $null }
    return $match.Value
}

function Get-PocBashFunction([string]$Name) {
    $content = Get-Content -LiteralPath $PocSh -Raw
    $match = [regex]::Match($content, "(?ms)^\s*(?:function\s+)?$Name(?:\s*\(\))?\s*\{.*?(?=^\s*(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*(?:\s*\(\))?\s*\{|\z)")
    if (-not $match.Success) { return $null }
    return $match.Value
}

function Get-EffectiveEnv {
    $lines = foreach ($line in Get-Content -LiteralPath $EnvExample) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        ($line -replace '\s*#.*$', '')
    }
    return ($lines -join "`n")
}

function Assert-ExactAssignment([string]$Path, [string]$Pattern, [string]$Message) {
    $matches = @(Get-Content -LiteralPath $Path | Where-Object { $_ -match $Pattern })
    if ($matches.Count -ne 1) { Fail $Message }
}

function Assert-ReadOnlyDoctorBody([string]$Body, [string]$Label, [switch]$IsWrapper) {
    if ($Body -match '(?i)Invoke-PocCompose|docker(?:\s+)?compose|docker-compose') {
        Fail "$Label must not invoke Compose"
    }
    if ($Body -match '(?i)docker\.exe|\$DOCKER|\$\{DOCKER|Invoke-Expression|Remove-Item|Set-Content|Add-Content|New-Item|Copy-Item|Move-Item|Start-Process|Stop-Process|Start-Service|Stop-Service|Restart-Service') {
        Fail "$Label uses a forbidden mutating or variable Docker command"
    }
    if ($IsWrapper) {
        $allowed = @('port', 'logs', 'inspect', '$@', '"$@"', "'$@'", '$args', '$Arguments')
        $verbs = New-Object System.Collections.Generic.List[string]
        foreach ($match in [regex]::Matches($Body, '(?i)(?:^|[^\w-])docker(?:\.exe)?\s+([^\s;|]+)')) {
            $verbs.Add($match.Groups[1].Value.Trim('''"'))
        }
        foreach ($match in [regex]::Matches($Body, "(?i)Invoke-Native\s+docker\s+@?\(?\s*['`"]?([^\s,'`")]+)")) {
            $verbs.Add($match.Groups[1].Value.Trim('''"'))
        }
        if ($verbs.Count -eq 0) {
            Fail "$Label must invoke docker port, logs, or inspect"
        }
        foreach ($verb in $verbs) {
            if ($verb -notin $allowed) {
                Fail "$Label may only invoke docker port, logs, inspect, or `$args (found $verb)"
            }
        }
        return
    }
    if ($Body -match '(?i)(^|[^\w-])docker(\s|\.|$)') {
        Fail "$Label must call the read-only Docker wrapper, not docker"
    }
    if ($Body -match '(?i)Invoke-Native\s+docker') {
        Fail "$Label must not call Invoke-Native docker directly"
    }
}

function Assert-PowerShellDoctorReachability([string]$FunctionName, [hashtable]$Visited) {
    if ($Visited.ContainsKey($FunctionName)) { return }
    $Visited[$FunctionName] = $true
    $body = Get-PocPowerShellFunction $FunctionName
    if ([string]::IsNullOrWhiteSpace($body)) { Fail "poc.ps1 doctor helper $FunctionName must exist" }
    $body = (($body -split "`r?`n" | ForEach-Object { $_ -replace '\s*#.*$', '' }) -join "`n")
    Assert-ReadOnlyDoctorBody $body "poc.ps1 doctor helper $FunctionName" -IsWrapper:($FunctionName -eq 'Invoke-PocDockerReadOnly')
    foreach ($match in [regex]::Matches($script:PocPs1Content, '(?mi)^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\b')) {
        $helper = $match.Groups[1].Value
        if ($helper -ne $FunctionName -and $body -match "(?i)(^|[^\w-])$([regex]::Escape($helper))(\s|\(|$)") {
            Assert-PowerShellDoctorReachability $helper $Visited
        }
    }
}

function Assert-BashDoctorReachability([string]$FunctionName, [hashtable]$Visited) {
    if ($Visited.ContainsKey($FunctionName)) { return }
    $Visited[$FunctionName] = $true
    $body = Get-PocBashFunction $FunctionName
    if ([string]::IsNullOrWhiteSpace($body)) { Fail "poc.sh doctor helper $FunctionName must exist" }
    $body = (($body -split "`r?`n" | ForEach-Object { $_ -replace '\s*#.*$', '' }) -join "`n")
    if ($FunctionName -eq 'compose') { Fail 'poc.sh doctor must not reach the compose helper' }
    if ($body -match '(?i)(^|[^\w-])(docker\s+compose|docker-compose)(\s|$)') {
        Fail "poc.sh doctor helper $FunctionName must not invoke Compose"
    }
    if ($body -match '(?i)docker\.exe|\$DOCKER|\$\{DOCKER|rm\s+-|\bsystemctl\b|\bkill\b') {
        Fail "poc.sh doctor helper $FunctionName uses a forbidden Docker or mutating command"
    }
    if ($FunctionName -eq 'docker_readonly') {
        $allowed = @('port', 'logs', 'inspect', '$@', '"$@"', "'$@'")
        $verbs = foreach ($match in [regex]::Matches($body, '(?i)(?:^|[^\w-])docker(?:\.exe)?\s+([^\s;|]+)')) {
            $match.Groups[1].Value.Trim('''"')
        }
        if (@($verbs).Count -eq 0) {
            Fail 'docker_readonly must invoke docker port, logs, or inspect'
        }
        foreach ($verb in $verbs) {
            if ($verb -notin $allowed) {
                Fail "docker_readonly may only invoke docker port, logs, inspect, or `$@ (found $verb)"
            }
        }
    } elseif ($body -match '(^|[^\w-])docker\s+') {
        Fail "poc.sh doctor helper $FunctionName must call docker_readonly, not docker"
    }
    foreach ($match in [regex]::Matches($script:PocShContent, '(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)(?:\s*\(\))?\s*\{')) {
        $helper = $match.Groups[1].Value
        if ($helper -ne $FunctionName -and $body -match "(^|[^\w-])$([regex]::Escape($helper))(\s|\(|$)") {
            Assert-BashDoctorReachability $helper $Visited
        }
    }
}

function Assert-PinnedBuildLog([string]$LogPath) {
    $line = Get-Content -LiteralPath $LogPath | Where-Object { $_ -match 'buildx' } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) { Fail 'mocked build must run docker buildx' }
    $tokens = @("$line".Trim() -split '\s+')
    $noValue = @('--load', '--push', '--pull', '--no-cache', '--quiet', '-q', '--rm')
    $positional = New-Object System.Collections.Generic.List[string]
    $tag = $null
    $revisionLabel = $false
    $expectedContext = "$SourceRepository.git#$SourceCommit"
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($token -in @('buildx', 'build') -or $token -in $noValue) { continue }
        if ($token -in @('-t', '--tag') -and ($i + 1) -lt $tokens.Count) {
            $tag = $tokens[$i + 1]
            $i++
            continue
        }
        if ($token.StartsWith('--tag=')) { $tag = $token.Substring(6); continue }
        if ($token -eq '--label' -and ($i + 1) -lt $tokens.Count) {
            if ($tokens[$i + 1] -eq "org.opencontainers.image.revision=$SourceCommit") { $revisionLabel = $true }
            $i++
            continue
        }
        if ($token.StartsWith('--label=') -and $token.Substring(8) -eq "org.opencontainers.image.revision=$SourceCommit") {
            $revisionLabel = $true
            continue
        }
        if ($token.StartsWith('-') -and ($i + 1) -lt $tokens.Count -and -not $tokens[$i + 1].StartsWith('-')) {
            $i++
            continue
        }
        if ($token.StartsWith('-')) { continue }
        $positional.Add($token)
    }
    if ($positional.Count -eq 0 -or $positional[-1] -ne $expectedContext) {
        Fail "mocked build context must be the final positional argument $expectedContext"
    }
    if ($tag -ne $ExpectedImage) { Fail "mocked build -t/--tag must be $ExpectedImage" }
    if (-not $revisionLabel) { Fail 'mocked build must label org.opencontainers.image.revision with the pinned commit' }
}

function Assert-BashDestroyReachability([string]$FunctionName, [hashtable]$Visited) {
    if ($Visited.ContainsKey($FunctionName)) { return }
    $Visited[$FunctionName] = $true
    $body = Get-PocBashFunction $FunctionName
    if ([string]::IsNullOrWhiteSpace($body)) { Fail "poc.sh destroy helper $FunctionName must exist" }
    $body = (($body -split "`r?`n" | ForEach-Object { $_ -replace '\s*#.*$', '' }) -join "`n")
    if ($FunctionName -eq 'compose') {
        if ($body -notmatch '-f\s+"?\$\{?COMPOSE_FILE') { Fail 'compose helper must pass the POC compose file' }
        if ($body -notmatch '(-p|--project-name)\s+"?\$\{?PROJECT_NAME') { Fail 'compose helper must pass the fixed POC project name' }
        if ($body -match '(?i)(--volumes|rmi|\brm\s+)') { Fail 'compose helper must not delete volumes, images, or files' }
    } elseif ($FunctionName -eq 'cmd_destroy') {
        if ($body -notmatch '(?m)^\s*compose\s+down\s+--remove-orphans\s*$') {
            Fail 'poc.sh destroy must run compose down --remove-orphans'
        }
        if ($body -match '(?i)(--volumes|rmi|\brm\s+|docker\s+|systemctl|\bkill\b)') {
            Fail 'cmd_destroy must not delete files or call docker directly'
        }
    } elseif ($body -match '(?i)(--volumes|rmi|\brm\s+|docker\s+|docker\.exe|Remove-Item|systemctl|\bkill\b)') {
        Fail "poc.sh destroy helper $FunctionName must not delete volumes, networks, images, or files"
    }
    foreach ($match in [regex]::Matches($script:PocShContent, '(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)(?:\s*\(\))?\s*\{')) {
        $helper = $match.Groups[1].Value
        if ($helper -ne $FunctionName -and $body -match "(^|[^\w-])$([regex]::Escape($helper))(\s|\(|$)") {
            Assert-BashDestroyReachability $helper $Visited
        }
    }
}

function Assert-PowerShellDestroyReachability([string]$FunctionName, [hashtable]$Visited) {
    if ($Visited.ContainsKey($FunctionName)) { return }
    $Visited[$FunctionName] = $true
    $body = Get-PocPowerShellFunction $FunctionName
    if ([string]::IsNullOrWhiteSpace($body)) { Fail "poc.ps1 destroy helper $FunctionName must exist" }
    $body = (($body -split "`r?`n" | ForEach-Object { $_ -replace '\s*#.*$', '' }) -join "`n")
    if ($FunctionName -eq 'Invoke-PocCompose') {
        if ($body -notmatch '(?i)(-f|--file)\s+\$script:ComposeFile') { Fail 'Invoke-PocCompose must pass the POC compose file' }
        if ($body -notmatch '(?i)(-p|--project-name)\s+\$script:ProjectName') { Fail 'Invoke-PocCompose must pass the fixed POC project name' }
        if ($body -match '(?i)(--volumes|rmi|Remove-Item)') { Fail 'Invoke-PocCompose must not delete volumes, images, or files' }
    } elseif ($FunctionName -eq 'Invoke-PocDestroy') {
        if ($body -notmatch "Invoke-PocCompose\s+@\(['`"]down['`"]\s*,\s*['`"]--remove-orphans['`"]\)") {
            Fail 'poc.ps1 destroy must run Invoke-PocCompose down --remove-orphans'
        }
        if ($body -match '(?i)(--volumes|rmi|Remove-Item|docker\s+|docker\.exe)') {
            Fail 'Invoke-PocDestroy must not delete files or call docker directly'
        }
    } elseif ($body -match '(?i)(--volumes|rmi|Remove-Item|docker\s+|docker\.exe|Stop-Process|Stop-Service)') {
        Fail "poc.ps1 destroy helper $FunctionName must not delete volumes, networks, images, or files"
    }
    foreach ($match in [regex]::Matches($script:PocPs1Content, '(?mi)^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\b')) {
        $helper = $match.Groups[1].Value
        if ($helper -ne $FunctionName -and $body -match "(?i)(^|[^\w-])$([regex]::Escape($helper))(\s|\(|$)") {
            Assert-PowerShellDestroyReachability $helper $Visited
        }
    }
}

function Assert-EffectiveCompose([string]$JsonText) {
    $cfg = $JsonText | ConvertFrom-Json
    if ($cfg.name -ne $ProjectName) { Fail "Compose project name must be $ProjectName" }
    $serviceNames = @($cfg.services.PSObject.Properties.Name)
    if ($serviceNames.Count -ne 1 -or $serviceNames[0] -ne 'cursor-bridge') {
        Fail 'Compose must define exactly one service: cursor-bridge'
    }
    $svc = $cfg.services.'cursor-bridge'
    if ($svc.image -ne $ExpectedImage) { Fail "Effective image must be $ExpectedImage" }
    if ($null -ne $svc.build) { Fail 'Compose must not declare a build section' }
    if ($svc.pull_policy -ne 'never') { Fail 'pull_policy must be never' }
    $ports = @($svc.ports)
    if ($ports.Count -ne 1) { Fail 'Compose must publish exactly one host mapping' }
    $port = $ports[0]
    if ($port.host_ip -ne '127.0.0.1' -or [int]$port.target -ne 8765 -or [string]$port.published -ne '18765' -or $port.protocol -ne 'tcp') {
        Fail 'Effective publish must be 127.0.0.1:18765:8765/tcp'
    }
    if ($null -ne $svc.expose -and @($svc.expose).Count -gt 0) {
        Fail 'Compose must not declare expose, including 8765'
    }
    if ($svc.privileged -eq $true) { Fail 'privileged must not be enabled' }
    if ($svc.network_mode -eq 'host') { Fail 'network_mode must not be host' }
    if ($svc.pid -eq 'host') { Fail 'pid mode must not be host' }
    if ($svc.ipc -eq 'host') { Fail 'ipc mode must not be host' }
    foreach ($key in @('volumes', 'volumes_from', 'devices', 'configs', 'secrets', 'tmpfs')) {
        $value = $svc.$key
        if ($null -ne $value -and @($value).Count -gt 0) {
            Fail "cursor-bridge must not define $key"
        }
    }
    if (@($svc.cap_drop) -join ',' -ne 'ALL') { Fail 'cap_drop must be ALL' }
    if (@($svc.security_opt) -notcontains 'no-new-privileges:true') { Fail 'security_opt must include no-new-privileges:true' }
    if ([int]$svc.pids_limit -ne 128) { Fail 'pids_limit must be 128' }
    if ([int64]$svc.mem_limit -ne 2147483648) { Fail 'memory must be 2 GiB' }
    if ([double]$svc.cpus -ne 2) { Fail 'CPUs must be 2' }
    if ($svc.init -ne $true) { Fail 'init must be true' }
    if ($svc.environment -isnot [pscustomobject] -and $svc.environment -isnot [hashtable]) {
        Fail 'Compose must use an explicit environment map'
    }
    if ($null -ne $svc.env_file -and @($svc.env_file).Count -gt 0) {
        Fail 'Compose must not use env_file; keep an explicit environment map'
    }
    $required = @{
        CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE = 'true'
        CURSOR_BRIDGE_MODE = 'ask'
        CURSOR_BRIDGE_FORCE = 'false'
        CURSOR_BRIDGE_APPROVE_MCPS = 'false'
        CURSOR_BRIDGE_VERBOSE = 'false'
        CURSOR_BRIDGE_MAX_MODE = 'false'
        CURSOR_BRIDGE_USE_ACP = 'true'
        CURSOR_BRIDGE_ACP_RAW_DEBUG = 'false'
        CURSOR_BRIDGE_MULTI_PORT = 'false'
    }
    foreach ($key in $required.Keys) {
        if ([string]$svc.environment.$key -ne $required[$key]) {
            Fail "effective environment $key must be $($required[$key])"
        }
    }
    foreach ($key in @('CURSOR_CONFIG_DIRS', 'CURSOR_ACCOUNT_DIRS')) {
        if ($null -ne $svc.environment.$key) { Fail "$key must remain unset" }
    }
    if ($null -ne $cfg.networks) {
        foreach ($netProp in $cfg.networks.PSObject.Properties) {
            $net = $netProp.Value
            if ($net.external) { Fail 'POC networks must not be external' }
            $joined = "$($netProp.Name) $($net.name)"
            if ($joined -match 'cli-proxy|sub2api') {
                Fail 'POC must not join a live CPA or Sub2API network'
            }
        }
    }
}

function Write-MockDocker {
    param([string]$Directory)
    $python = @'
import os
import sys

log_path = os.environ["MOCK_DOCKER_LOG"]
with open(log_path, "a", encoding="utf-8") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")

args = sys.argv[1:]
if not args:
    sys.exit(1)
if args[0] == "port":
    print("127.0.0.1:18765")
    sys.exit(0)
if args[0] == "logs":
    print("cursor-bridge ready")
    sys.exit(0)
if args[0] == "image" and "inspect" in args:
    print("sha256:test-image-id")
    sys.exit(0)
if args[0] == "inspect":
    if any(arg == "--format" or arg.startswith("--format=") for arg in args):
        print('app 2147483648 128 ["no-new-privileges:true"] ["ALL"]')
    else:
        print('[{"Config":{"User":"app"},"HostConfig":{"Memory":2147483648,"PidsLimit":128,"SecurityOpt":["no-new-privileges:true"],"CapDrop":["ALL"]}}]')
    sys.exit(0)
sys.exit(0)
'@
    Set-Content -LiteralPath (Join-Path $Directory 'docker_mock.py') -Value $python -Encoding utf8
    $cmd = @"
@echo off
python "%~dp0docker_mock.py" %*
"@
    Set-Content -LiteralPath (Join-Path $Directory 'docker.cmd') -Value $cmd -Encoding ascii
}

function Write-MockHttpRunner([string]$RunnerPath, [string]$PocPath) {
    $escaped = $PocPath.Replace("'", "''")
    $runner = @"
`$ErrorActionPreference = 'Stop'
function Invoke-WebRequest {
    param(
        [string]`$Uri,
        [string]`$Method = 'Get',
        [hashtable]`$Headers,
        [int]`$TimeoutSec,
        [switch]`$SkipHttpErrorCheck,
        [string]`$ContentType,
        [object]`$Body
    )
    if (`$Uri -match 'healthz') { return [pscustomobject]@{ StatusCode = 200; Content = 'ok' } }
    if (`$Uri -match '/v1/models' -and -not (`$Headers -and `$Headers.Authorization)) {
        return [pscustomobject]@{ StatusCode = 401; Content = '' }
    }
    if (`$Uri -match '/health') {
        return [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true,"mode":"ask","force":false,"approveMcps":false}' }
    }
    if (`$Uri -match '/v1/models') {
        return [pscustomobject]@{ StatusCode = 200; Content = '{"object":"list","data":[{"id":"test-model"}]}' }
    }
    if (`$Uri -match 'chat/completions') {
        return [pscustomobject]@{ StatusCode = 200; Content = "data: STREAM_OK``n" }
    }
    return [pscustomobject]@{ StatusCode = 200; Content = 'ok' }
}
function Invoke-RestMethod {
    param(
        [string]`$Uri,
        [string]`$Method = 'Get',
        [hashtable]`$Headers,
        [int]`$TimeoutSec,
        [string]`$ContentType,
        [object]`$Body
    )
    if (`$Uri -match '/health' -and `$Uri -notmatch 'healthz') {
        return [pscustomobject]@{ ok = `$true; mode = 'ask'; force = `$false; approveMcps = `$false }
    }
    if (`$Uri -match '/v1/models') {
        return [pscustomobject]@{ object = 'list'; data = @([pscustomobject]@{ id = 'test-model' }) }
    }
    if (`$Uri -match 'chat/completions') {
        return [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'CURSOR_POC_OK' } }) }
    }
    throw "unexpected URI `$Uri"
}
. '$escaped'
if (-not (Get-Command Invoke-Main -ErrorAction SilentlyContinue)) { throw 'poc.ps1 must define Invoke-Main' }
Invoke-Main -Arguments `$args
"@
    Set-Content -LiteralPath $RunnerPath -Value $runner -Encoding utf8
}

foreach ($rel in @(
    'poc/cursor-bridge/docker-compose.yml',
    'poc/cursor-bridge/poc.env.example',
    'poc/cursor-bridge/poc.sh',
    'poc/cursor-bridge/poc.ps1'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $RootDir $rel) -PathType Leaf)) {
        Fail "Missing required POC file: $rel"
    }
}

$imageLines = @(Get-Content -LiteralPath $ComposeFile | Where-Object { $_ -match '^\s*image:\s*' })
if ($imageLines.Count -ne 1) { Fail 'Compose must define exactly one image: line' }
$imageLine = $imageLines[0].Trim()
if ($imageLine -ne "image: $ExpectedImage") { Fail "Compose image must be hard-coded as $ExpectedImage" }
if ($imageLine.Contains('$')) { Fail 'Compose image must not use a variable or default interpolation' }

Assert-Contains $ComposeFile $ExpectedPortLine "Compose source must use the exact loopback mapping $ExpectedPortLine"
Assert-NotContains $ComposeFile 'CURSOR_BRIDGE_POC_IMAGE' 'Compose must not accept a CURSOR_BRIDGE_POC_IMAGE override'
Assert-NotContains $EnvExample 'CURSOR_BRIDGE_POC_IMAGE' 'Environment example must not define CURSOR_BRIDGE_POC_IMAGE'
Assert-NotContains $EnvExample 'latest' 'Environment example must not use a latest tag'

$effectiveEnv = Get-EffectiveEnv
foreach ($setting in @(
    'CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true',
    'CURSOR_BRIDGE_MODE=ask',
    'CURSOR_BRIDGE_FORCE=false',
    'CURSOR_BRIDGE_APPROVE_MCPS=false',
    'CURSOR_BRIDGE_VERBOSE=false',
    'CURSOR_BRIDGE_MAX_MODE=false',
    'CURSOR_BRIDGE_USE_ACP=true',
    'CURSOR_BRIDGE_ACP_RAW_DEBUG=false',
    'CURSOR_BRIDGE_MULTI_PORT=false'
)) {
    $name, $value = $setting -split '=', 2
    $assignments = @($effectiveEnv -split "`n" | Where-Object { $_ -match "^$name=" })
    if ($assignments.Count -ne 1 -or $assignments[0].Trim() -ne $setting) {
        Fail "Environment example must define exactly one safe $setting"
    }
}
if ($effectiveEnv.Contains('CURSOR_CONFIG_DIRS=')) { Fail 'Environment example must not define CURSOR_CONFIG_DIRS' }
if ($effectiveEnv.Contains('CURSOR_ACCOUNT_DIRS=')) { Fail 'Environment example must not define CURSOR_ACCOUNT_DIRS' }

$composeJson = (& docker compose --env-file $EnvExample -f $ComposeFile config --format json)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($composeJson)) {
    Fail 'docker compose config --format json failed'
}
Assert-EffectiveCompose (($composeJson | Out-String).Trim())

$psTokens = $null
$psErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($PocPs1, [ref]$psTokens, [ref]$psErrors)
if ($psErrors -and $psErrors.Count -gt 0) { Fail "poc.ps1 must parse: $($psErrors[0].Message)" }

$gitBash = 'C:\Program Files\Git\bin\bash.exe'
if (Test-Path -LiteralPath $gitBash) {
    & $gitBash -c "PATH=/usr/bin:/bin:`$PATH; /usr/bin/bash -n `"$($PocSh -replace '\\','/')`""
    if ($LASTEXITCODE -ne 0) { Fail 'poc.sh must pass bash -n' }
}

Assert-ExactAssignment $PocSh "^\s*(?:readonly\s+)?SOURCE_COMMIT=['`"]$([regex]::Escape($SourceCommit))['`"]\s*$" 'poc.sh must assign SOURCE_COMMIT exactly once'
Assert-ExactAssignment $PocSh "^\s*(?:readonly\s+)?SOURCE_REPOSITORY=['`"]$([regex]::Escape($SourceRepository))['`"]\s*$" 'poc.sh must pin SOURCE_REPOSITORY'
Assert-ExactAssignment $PocSh "^\s*(?:readonly\s+)?IMAGE_TAG=['`"]$([regex]::Escape($ExpectedImage))['`"]\s*$" 'poc.sh must hard-code IMAGE_TAG'
Assert-ExactAssignment $PocSh "^\s*(?:readonly\s+)?PROJECT_NAME=['`"]$([regex]::Escape($ProjectName))['`"]\s*$" 'poc.sh must use the dedicated project name'
Assert-ExactAssignment $PocPs1 ("^\s*\`$script:SourceCommit\s*=\s*['`"]{0}['`"]\s*$" -f [regex]::Escape($SourceCommit)) 'poc.ps1 must assign script:SourceCommit exactly once'
Assert-ExactAssignment $PocPs1 ("^\s*\`$script:SourceRepository\s*=\s*['`"]{0}['`"]\s*$" -f [regex]::Escape($SourceRepository)) 'poc.ps1 must pin script:SourceRepository'
Assert-ExactAssignment $PocPs1 ("^\s*\`$script:ImageTag\s*=\s*['`"]{0}['`"]\s*$" -f [regex]::Escape($ExpectedImage)) 'poc.ps1 must hard-code script:ImageTag'
Assert-ExactAssignment $PocPs1 ("^\s*\`$script:ProjectName\s*=\s*['`"]{0}['`"]\s*$" -f [regex]::Escape($ProjectName)) 'poc.ps1 must use the dedicated project name'

$script:PocShContent = Get-Content -LiteralPath $PocSh -Raw
$script:PocPs1Content = Get-Content -LiteralPath $PocPs1 -Raw
$bashDispatch = [regex]::Match($script:PocShContent, '(?ms)^\s*case\s+"\$\{1:-help\}"\s+in\s*$.*?^\s*esac\s*$')
if (-not $bashDispatch.Success) { Fail 'poc.sh must dispatch through the real top-level case' }
$psMain = Get-PocPowerShellFunction 'Invoke-Main'
if ([string]::IsNullOrWhiteSpace($psMain)) { Fail 'poc.ps1 must define Invoke-Main with the command switch' }

foreach ($command in $Commands) {
    if ($bashDispatch.Value -notmatch "(?m)^\s*$command\)\s*cmd_$command\s*;;") {
        Fail "poc.sh must dispatch $command to cmd_$command"
    }
    if ([string]::IsNullOrWhiteSpace((Get-PocBashFunction "cmd_$command"))) {
        Fail "poc.sh must define cmd_$command()"
    }
    $psCommand = $command.Substring(0, 1).ToUpperInvariant() + $command.Substring(1)
    $switchPattern = '(?m)^\s*[\x27\x22]' + [regex]::Escape($command) + '[\x27\x22]\s*\{\s*' + [regex]::Escape("Invoke-Poc$psCommand") + '\s*\}'
    if (-not [regex]::IsMatch($psMain, $switchPattern)) {
        Fail "poc.ps1 must dispatch $command to Invoke-Poc$psCommand"
    }
    if ([string]::IsNullOrWhiteSpace((Get-PocPowerShellFunction "Invoke-Poc$psCommand"))) {
        Fail "poc.ps1 must define Invoke-Poc$psCommand"
    }
}

if ([string]::IsNullOrWhiteSpace((Get-PocBashFunction 'docker_readonly'))) { Fail 'poc.sh must define docker_readonly' }
if ([string]::IsNullOrWhiteSpace((Get-PocPowerShellFunction 'Invoke-PocDockerReadOnly'))) { Fail 'poc.ps1 must define Invoke-PocDockerReadOnly' }
if ([string]::IsNullOrWhiteSpace((Get-PocBashFunction 'compose'))) { Fail 'poc.sh must define a compose helper' }
if ([string]::IsNullOrWhiteSpace((Get-PocPowerShellFunction 'Invoke-PocCompose'))) { Fail 'poc.ps1 must define Invoke-PocCompose' }

Assert-BashDoctorReachability 'cmd_doctor' @{}
Assert-PowerShellDoctorReachability 'Invoke-PocDoctor' @{}
Assert-BashDestroyReachability 'cmd_destroy' @{}
Assert-PowerShellDestroyReachability 'Invoke-PocDestroy' @{}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("cursor-bridge-poc-contract-{0}" -f [guid]::NewGuid().ToString('N'))
$workDir = Join-Path $tempRoot 'poc'
$mockBin = Join-Path $tempRoot 'mock-bin'
New-Item -ItemType Directory -Path $workDir, $mockBin | Out-Null
try {
    Copy-Item -LiteralPath $ComposeFile, $EnvExample, $PocSh, $PocPs1 -Destination $workDir
    @'
CURSOR_BRIDGE_POC_PORT=18765
CURSOR_API_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CURSOR_BRIDGE_API_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CURSOR_BRIDGE_HOST=0.0.0.0
CURSOR_BRIDGE_PORT=8765
CURSOR_BRIDGE_DEFAULT_MODEL=auto
CURSOR_BRIDGE_TIMEOUT_MS=300000
CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true
CURSOR_BRIDGE_MODE=ask
CURSOR_BRIDGE_FORCE=false
CURSOR_BRIDGE_APPROVE_MCPS=false
CURSOR_BRIDGE_STRICT_MODEL=true
CURSOR_BRIDGE_VERBOSE=false
CURSOR_BRIDGE_MAX_MODE=false
CURSOR_BRIDGE_USE_ACP=true
CURSOR_BRIDGE_PROMPT_VIA_STDIN=true
CURSOR_BRIDGE_ACP_RAW_DEBUG=false
CURSOR_BRIDGE_CONTEXT_PREAMBLE=true
CURSOR_BRIDGE_MULTI_PORT=false
'@ | Set-Content -LiteralPath (Join-Path $workDir 'poc.env') -Encoding utf8
    Write-MockDocker -Directory $mockBin

    $originalPath = $env:PATH
    $env:PATH = "$mockBin;$originalPath"
    try {
        $buildLog = Join-Path $tempRoot 'build.docker.log'
        $env:MOCK_DOCKER_LOG = $buildLog
        & pwsh -NoProfile -File (Join-Path $workDir 'poc.ps1') build
        if ($LASTEXITCODE -ne 0) { Fail 'mocked poc.ps1 build must succeed' }
        $buildText = Get-Content -LiteralPath $buildLog -Raw
        if ($buildText -notmatch 'buildx build') { Fail 'mocked build must run docker buildx build' }
        if (-not $buildText.Contains('--load')) { Fail 'mocked build must pass --load' }
        Assert-PinnedBuildLog $buildLog

        $runner = Join-Path $tempRoot 'invoke-poc.ps1'
        Write-MockHttpRunner -RunnerPath $runner -PocPath (Join-Path $workDir 'poc.ps1')
        $doctorLog = Join-Path $tempRoot 'doctor.docker.log'
        $env:MOCK_DOCKER_LOG = $doctorLog
        & pwsh -NoProfile -File $runner doctor
        if ($LASTEXITCODE -ne 0) { Fail 'mocked poc.ps1 doctor must succeed' }
        $doctorLines = @(Get-Content -LiteralPath $doctorLog -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
        if ($doctorLines.Count -eq 0) {
            Fail 'mocked doctor must invoke docker port, logs, or inspect'
        }
        foreach ($line in $doctorLines) {
            $verb = ($line.Trim() -split '\s+')[0]
            if ($verb -notin @('port', 'logs', 'inspect')) {
                Fail "mocked doctor Docker verb is not read-only: $line"
            }
        }

        $destroyLog = Join-Path $tempRoot 'destroy.docker.log'
        $env:MOCK_DOCKER_LOG = $destroyLog
        $beforeDestroy = @(Get-ChildItem -LiteralPath $workDir -Force | ForEach-Object { $_.Name } | Sort-Object)
        & pwsh -NoProfile -File (Join-Path $workDir 'poc.ps1') destroy
        if ($LASTEXITCODE -ne 0) { Fail 'mocked poc.ps1 destroy must succeed' }
        $destroyText = Get-Content -LiteralPath $destroyLog -Raw
        if ($destroyText -notmatch 'compose') { Fail 'mocked destroy must call docker compose' }
        if ($destroyText -notmatch 'down --remove-orphans') { Fail 'mocked destroy must pass down --remove-orphans' }
        if ($destroyText -notmatch [regex]::Escape("-p $ProjectName") -and $destroyText -notmatch [regex]::Escape("--project-name $ProjectName")) {
            Fail "mocked destroy must target project $ProjectName via -p or --project-name"
        }
        foreach ($forbidden in @('--volumes', 'rmi', 'volume', 'network')) {
            if ($destroyText.Contains($forbidden)) { Fail "mocked destroy must not delete $forbidden" }
        }
        if (@(Get-Content -LiteralPath $destroyLog | Where-Object { $_.Trim() }).Count -ne 1) {
            Fail 'mocked destroy must make exactly one Docker invocation'
        }
        $afterDestroy = @(Get-ChildItem -LiteralPath $workDir -Force | ForEach-Object { $_.Name } | Sort-Object)
        if (($beforeDestroy -join '|') -ne ($afterDestroy -join '|')) {
            Fail 'destroy must not add or delete files in the POC directory'
        }

        foreach ($command in @('start', 'status', 'logs', 'stop')) {
            $env:MOCK_DOCKER_LOG = Join-Path $tempRoot "$command.docker.log"
            & pwsh -NoProfile -File (Join-Path $workDir 'poc.ps1') $command
            if ($LASTEXITCODE -ne 0) { Fail "mocked poc.ps1 $command must dispatch successfully" }
        }
        $smokeLog = Join-Path $tempRoot 'smoke.docker.log'
        $env:MOCK_DOCKER_LOG = $smokeLog
        & pwsh -NoProfile -File $runner smoke
        if ($LASTEXITCODE -ne 0) { Fail 'mocked poc.ps1 smoke must succeed' }
        foreach ($line in @(Get-Content -LiteralPath $smokeLog -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })) {
            if ($line -match '(?i)(compose\s+down|--volumes|rmi|volume\s+rm|network\s+rm)') {
                Fail "mocked smoke must not destroy POC resources: $line"
            }
        }

        $env:MOCK_DOCKER_LOG = Join-Path $tempRoot 'unknown.docker.log'
        $unknownFailed = $false
        try {
            & pwsh -NoProfile -File (Join-Path $workDir 'poc.ps1') 'not-a-command'
            if ($LASTEXITCODE -ne 0) { $unknownFailed = $true }
        } catch {
            $unknownFailed = $true
        }
        if (-not $unknownFailed) { Fail 'poc.ps1 must reject unknown commands' }
    } finally {
        $env:PATH = $originalPath
        Remove-Item Env:MOCK_DOCKER_LOG -ErrorAction SilentlyContinue
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Output 'PASS: PowerShell Cursor Bridge POC contract matches the Bash contract'
