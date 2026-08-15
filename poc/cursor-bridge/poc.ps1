$ErrorActionPreference = 'Stop'
$script:ScriptDir = $PSScriptRoot
$script:ComposeFile = Join-Path $PSScriptRoot 'docker-compose.yml'
$script:EnvFile = Join-Path $PSScriptRoot 'poc.env'
$script:EnvExample = Join-Path $PSScriptRoot 'poc.env.example'
$script:MetadataFile = Join-Path $PSScriptRoot 'poc-metadata.json'
$script:ProjectName = 'cursor-bridge-poc'
$script:ContainerName = 'cursor-bridge-poc'
$script:SourceRepository = 'https://github.com/anyrobert/cursor-api-proxy'
$script:SourceCommit = 'c0ff1f941215027c0a8f658ca5d01f806559208f'
$script:ImageTag = 'cursor-api-proxy:poc-c0ff1f941215027c0a8f658ca5d01f806559208f'

function Fail {
    param([string]$Message)
    throw "ERROR: $Message"
}

function Get-PocEnv {
    param([string]$Name)
    if (-not (Test-Path $script:EnvFile -PathType Leaf)) { Fail 'run: .\poc.ps1 init' }
    foreach ($line in Get-Content -LiteralPath $script:EnvFile) {
        if ($line -match '^([^#=]+)=(.*)$' -and $Matches[1].Trim() -eq $Name) {
            return $Matches[2].Trim()
        }
    }
    return ''
}

function Assert-PocEnv {
    $cursorKey = Get-PocEnv 'CURSOR_API_KEY'
    $bridgeKey = Get-PocEnv 'CURSOR_BRIDGE_API_KEY'
    if (-not $cursorKey -or $cursorKey.StartsWith('replace-locally-')) { Fail 'CURSOR_API_KEY is not configured' }
    if ($bridgeKey -notmatch '^[A-Fa-f0-9]{64}$') { Fail 'CURSOR_BRIDGE_API_KEY must be 64 hex characters' }
    if ($cursorKey -eq $bridgeKey) { Fail 'Cursor and bridge keys must be different' }
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { Fail "$File failed with exit code $LASTEXITCODE" }
}

function Invoke-PocCompose {
    param([string[]]$Arguments)
    Write-Verbose "compose -f $script:ComposeFile -p $script:ProjectName"
    $composeArgs = @('compose', '--env-file', $script:EnvFile, '-f', $script:ComposeFile, '-p', $script:ProjectName) + $Arguments
    Invoke-Native docker $composeArgs
}

function Invoke-PocDockerReadOnly {
    param([string[]]$Arguments)
    $verb = $Arguments[0]
    switch ($verb) {
        'port' { }
        'logs' { }
        'inspect' { }
        default { Fail 'doctor may only use the port, logs, or inspect verbs' }
    }
    Invoke-Native docker $Arguments
}

function Invoke-PocInit {
    if (Test-Path $script:EnvFile) { Fail 'poc.env already exists' }
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $bridgeKey = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $content = (Get-Content -Raw -LiteralPath $script:EnvExample).Replace(
        'replace-locally-with-random-64-hex-key', $bridgeKey)
    $temporary = "$($script:EnvFile).tmp.$([guid]::NewGuid().ToString('N'))"
    $encoding = [Text.UTF8Encoding]::new($false)
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer = [IO.StreamWriter]::new($stream, $encoding)
        try { $writer.Write($content) } finally { $writer.Dispose() }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    Move-Item -LiteralPath $temporary -Destination $script:EnvFile
    if (-not $IsWindows) { & chmod 600 $script:EnvFile }
    Write-Host 'INFO: Created poc.env. Edit CURSOR_API_KEY locally before build/start.'
}

function Invoke-PocBuild {
    Assert-PocEnv
    Invoke-Native docker @(
        'buildx', 'build', '--load',
        '--label', "org.opencontainers.image.source=$($script:SourceRepository)",
        '--label', "org.opencontainers.image.revision=$($script:SourceCommit)",
        '-t', $script:ImageTag,
        "$($script:SourceRepository).git#$($script:SourceCommit)"
    )
    $imageId = (& docker image inspect $script:ImageTag --format '{{.Id}}').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $imageId) { Fail 'cannot inspect the built image' }
    [ordered]@{
        source_commit = $script:SourceCommit
        image = $script:ImageTag
        image_id = $imageId
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:MetadataFile -NoNewline
    if (-not $IsWindows) { & chmod 600 $script:MetadataFile }
    Write-Host "INFO: Built and recorded $($script:ImageTag)"
}

function Invoke-PocStart {
    Assert-PocEnv
    Invoke-PocCompose @('config', '--quiet')
    Invoke-PocCompose @('up', '-d')
}

function Invoke-PocStop { Assert-PocEnv; Invoke-PocCompose @('stop') }
function Invoke-PocDestroy {
    Invoke-PocCompose @('down', '--remove-orphans')
}
function Invoke-PocLogs { Assert-PocEnv; Invoke-PocCompose @('logs', '--tail', '200', 'cursor-bridge') }

function Invoke-PocStatus {
    Assert-PocEnv
    Invoke-PocCompose @('ps')
    Invoke-Native docker @(
        'inspect', $script:ContainerName, '--format',
        'User={{.Config.User}} Image={{.Image}} Restart={{.RestartCount}} OOM={{.State.OOMKilled}} Ports={{json .HostConfig.PortBindings}}'
    )
}

function Invoke-PocDoctor {
    Assert-PocEnv
    $port = Get-PocEnv 'CURSOR_BRIDGE_POC_PORT'; if (-not $port) { $port = '18765' }
    $bridgeKey = Get-PocEnv 'CURSOR_BRIDGE_API_KEY'
    $cursorKey = Get-PocEnv 'CURSOR_API_KEY'
    $base = "http://127.0.0.1:$port"
    $binding = (Invoke-PocDockerReadOnly @('port', $script:ContainerName, '8765/tcp')).Trim()
    if ($binding -ne "127.0.0.1:$port") { Fail 'bridge is not loopback-only' }
    $healthz = Invoke-WebRequest -Uri "$base/healthz" -Method Get -TimeoutSec 10
    if ($healthz.Content.Trim() -ne 'ok') { Fail 'liveness failed' }
    $unauthorized = Invoke-WebRequest -Uri "$base/v1/models" -Method Get -SkipHttpErrorCheck -TimeoutSec 10
    if ([int]$unauthorized.StatusCode -ne 401) { Fail "unauthenticated models returned $($unauthorized.StatusCode)" }
    $headers = @{ Authorization = "Bearer $bridgeKey" }
    $health = Invoke-RestMethod -Uri "$base/health" -Headers $headers -TimeoutSec 10
    if (-not $health.ok -or $health.mode -ne 'ask' -or $health.force -ne $false -or $health.approveMcps -ne $false) {
        Fail 'safe health contract failed'
    }
    $models = Invoke-RestMethod -Uri "$base/v1/models" -Headers $headers -TimeoutSec 70
    if ($models.object -ne 'list' -or @($models.data).Count -eq 0) { Fail 'model discovery failed' }
    $logs = (Invoke-PocDockerReadOnly @('logs', $script:ContainerName) | Out-String)
    if ($logs.Contains($bridgeKey) -or $logs.Contains($cursorKey)) { Fail 'a credential appears in logs' }
    $inspectJson = Invoke-PocDockerReadOnly @('inspect', $script:ContainerName) | Out-String
    $inspect = ($inspectJson | ConvertFrom-Json)[0]
    if ($inspect.Config.User -ne 'app') { Fail 'container user is not app' }
    if ([int64]$inspect.HostConfig.Memory -ne 2147483648) { Fail 'memory limit is not 2 GiB' }
    if ([int64]$inspect.HostConfig.PidsLimit -ne 128) { Fail 'PID limit is not 128' }
    if (@($inspect.HostConfig.SecurityOpt) -notcontains 'no-new-privileges:true') { Fail 'no-new-privileges is missing' }
    if (@($inspect.HostConfig.CapDrop) -notcontains 'ALL') { Fail 'ALL capabilities are not dropped' }
    Write-Host 'INFO: Doctor PASS'
}

function Invoke-PocSmoke {
    Assert-PocEnv
    $port = Get-PocEnv 'CURSOR_BRIDGE_POC_PORT'; if (-not $port) { $port = '18765' }
    $bridgeKey = Get-PocEnv 'CURSOR_BRIDGE_API_KEY'
    $base = "http://127.0.0.1:$port"
    $headers = @{ Authorization = "Bearer $bridgeKey" }
    $models = Invoke-RestMethod -Uri "$base/v1/models" -Headers $headers -TimeoutSec 70
    $model = @($models.data)[0].id
    $syncBody = [ordered]@{
        model = $model
        messages = @([ordered]@{ role = 'user'; content = 'Reply with exactly CURSOR_POC_OK' })
        stream = $false
    } | ConvertTo-Json -Depth 6 -Compress
    $sync = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Headers $headers `
        -ContentType 'application/json' -Method Post -Body $syncBody -TimeoutSec 180
    if ($sync.choices[0].message.content -notlike '*CURSOR_POC_OK*') { Fail 'synchronous smoke failed' }
    $streamBody = [ordered]@{
        model = $model
        messages = @([ordered]@{ role = 'user'; content = 'Reply with exactly STREAM_OK' })
        stream = $true
    } | ConvertTo-Json -Depth 6 -Compress
    $stream = Invoke-WebRequest -Uri "$base/v1/chat/completions" -Headers $headers `
        -ContentType 'application/json' -Method Post -Body $streamBody -TimeoutSec 180
    if ($stream.Content -notmatch '(?m)^data:') { Fail 'streaming smoke failed' }
    Write-Host 'INFO: Smoke PASS'
}

function Invoke-Main {
    param([string[]]$Arguments)
    $command = if ($Arguments.Count -gt 0) { $Arguments[0] } else { 'help' }
    switch ($command) {
        'init' { Invoke-PocInit }
        'build' { Invoke-PocBuild }
        'start' { Invoke-PocStart }
        'status' { Invoke-PocStatus }
        'doctor' { Invoke-PocDoctor }
        'smoke' { Invoke-PocSmoke }
        'logs' { Invoke-PocLogs }
        'stop' { Invoke-PocStop }
        'destroy' { Invoke-PocDestroy }
        'help' { Write-Host 'Usage: .\poc.ps1 init|build|start|status|doctor|smoke|logs|stop|destroy' }
        '--help' { Write-Host 'Usage: .\poc.ps1 init|build|start|status|doctor|smoke|logs|stop|destroy' }
        '-h' { Write-Host 'Usage: .\poc.ps1 init|build|start|status|doctor|smoke|logs|stop|destroy' }
        default { Fail "unknown command: $command" }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main -Arguments $args }
