$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$bashCandidates = @(
    'C:\Program Files\Git\bin\bash.exe',
    'bash'
)
$bashPath = $null
foreach ($candidate in $bashCandidates) {
    if ([IO.Path]::IsPathRooted($candidate)) {
        if (Test-Path $candidate -PathType Leaf) { $bashPath = $candidate; break }
    } else {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { $bashPath = $command.Source; break }
    }
}
if (-not $bashPath) { throw 'FAIL: Bash is unavailable for schema parity test' }

function Get-SchemaPaths($value, [string]$prefix = '') {
    $paths = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $value) { return @($paths) }
    if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string]) -and
        -not ($value -is [pscustomobject]) -and -not ($value -is [System.Collections.IDictionary])) {
        $paths.Add("$prefix[]") | Out-Null
        $items = @($value)
        if ($items.Count -gt 0) {
            foreach ($path in Get-SchemaPaths $items[0] "$prefix[]") { $paths.Add($path) | Out-Null }
        }
        return @($paths)
    }
    if ($value -is [pscustomobject] -or $value -is [System.Collections.IDictionary]) {
        foreach ($property in $value.PSObject.Properties) {
            $path = if ($prefix) { "$prefix.$($property.Name)" } else { $property.Name }
            $paths.Add($path) | Out-Null
            foreach ($child in Get-SchemaPaths $property.Value $path) { $paths.Add($child) | Out-Null }
        }
    }
    return @($paths)
}

Push-Location $rootDir
try {
    $bashText = (& $bashPath '-c' 'PATH="/usr/bin:/bin:${PATH}"; exec bash ./deploy.sh capabilities --json' 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'FAIL: Bash capabilities command failed during schema parity test' }
    $powerShellText = (& (Join-Path $rootDir 'deploy.ps1') 'capabilities' '--json' 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'FAIL: PowerShell capabilities command failed during schema parity test' }

    $bashData = $bashText | ConvertFrom-Json -Depth 20
    $powerShellData = $powerShellText | ConvertFrom-Json -Depth 20
    if ($bashData.schema_version -ne 1 -or $powerShellData.schema_version -ne 1) {
        throw 'FAIL: schema_version must remain 1 on both platforms'
    }

    $bashPaths = @(Get-SchemaPaths $bashData | Sort-Object -Unique)
    $powerShellPaths = @(Get-SchemaPaths $powerShellData | Sort-Object -Unique)
    $difference = Compare-Object $bashPaths $powerShellPaths
    if ($difference) {
        $details = ($difference | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join '; '
        throw "FAIL: Bash/PowerShell schema paths differ: $details"
    }

    $requiredPaths = @(
        'management_ui.enabled',
        'management_ui.version',
        'management_ui.external_https_protection',
        'release_contract.cpa_version',
        'release_contract.cpa_commit',
        'release_contract.management_center_version',
        'release_contract.management_center_commit',
        'release_contract.compatibility_status',
        'official_capabilities.priority_write_supported',
        'official_capabilities.plugin_system_enabled',
        'routing.strategy',
        'routing.weighted_round_robin_supported',
        'routing.priority_configured',
        'routing.credential_weights_configured',
        'routing.session_affinity_enabled',
        'routing.session_affinity_ttl',
        'routing.automatic_failover_supported',
        'routing.wrr_traffic_validation',
        'plugins.items',
        'security.plugin_resource_pages_management_authenticated',
        'credentials.providers.kimi',
        'credentials.providers.xai',
        'credentials.additional_providers'
    )
    foreach ($path in $requiredPaths) {
        if ($bashPaths -notcontains $path) { throw "FAIL: required schema path is missing: $path" }
    }

    Write-Host 'PASS: Bash and PowerShell capability schemas match at version 1'
} finally {
    Pop-Location
}
