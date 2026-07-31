$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$deployScript = Join-Path $rootDir 'deploy.ps1'
. $deployScript

function Assert-Equal($actual, $expected, $message) {
    if ($actual -ne $expected) {
        throw "FAIL: $message (actual=$actual expected=$expected)"
    }
}

function Assert-True($condition, $message) {
    if (-not $condition) { throw "FAIL: $message" }
}

$testDir = Join-Path ([IO.Path]::GetTempPath()) ("cpa-capabilities-test-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$nativeCalls = [System.Collections.Generic.List[string]]::new()
$webCalls = [System.Collections.Generic.List[string]]::new()
$script:fallbackUsed = $false

try {
    $script:SCRIPT_DIR = $testDir
    $script:CONFIG_FILE = Join-Path $testDir 'config.yaml'
    $script:COMPOSE_FILE = Join-Path $testDir 'docker-compose.yml'
    $script:CPA_PORT = '8317'
    $script:CPA_API_KEY = ''
    $script:CPA_MANAGEMENT_KEY = 'management-plaintext-never-print'
    $script:DOCKER_IMAGE = 'eceasy/cli-proxy-api:latest'
    $env:CPA_BIND_HOST = '0.0.0.0'
    Remove-Item Env:CPA_EXPOSURE_MODE -ErrorAction SilentlyContinue

    @'
api-keys:
  - "sk-test-secret-never-print"
remote-management:
  allow-remote: true
  secret-key: "management-hash-never-print"
  disable-control-panel: false
plugins:
  enabled: true
routing:
  strategy: weighted-round-robin
  session-affinity: true
  session-affinity-ttl: "45m"
'@ | Set-Content -LiteralPath $script:CONFIG_FILE
    Set-Content -LiteralPath $script:COMPOSE_FILE -Value 'services: {}'

    function docker { }
    function detect-compose { return 'docker compose' }
    function Get-LatestCpaBackupTime { return '2026-07-27T12:00:00Z' }
    function Invoke-ReadOnlyNative {
        param([string]$File, [string[]]$Arguments = @())
        $call = "$File $($Arguments -join ' ')".Trim()
        $nativeCalls.Add($call) | Out-Null
        $output = @()
        $exitCode = 0
        if ($call -eq 'docker info') { }
        elseif ($call -match '^docker compose .* config --quiet$') { }
        elseif ($call -match '^docker inspect --format .* cli-proxy-manager$') {
            $output = @('eceasy/cli-proxy-api:latest|sha256:live-image-id|true')
        } elseif ($call -eq 'docker port cli-proxy-manager 8317/tcp') {
            $output = @('0.0.0.0:8317')
        } elseif ($call -match '^docker image inspect --format .* sha256:live-image-id$') {
            $output = @('eceasy/cli-proxy-api@sha256:repository-digest')
        } elseif ($call -eq 'docker image inspect eceasy/cli-proxy-api:rollback') { }
        elseif ($call -eq 'docker logs --tail 5000 cli-proxy-manager') {
            $output = @('CLIProxyAPI Version: v7.2.111, Commit: 4a31513, BuildDate: test')
        } elseif ($call -match '^docker exec cli-proxy-manager sh -c .*ldd /proc/1/exe') {
            $output = @('true')
        } elseif ($call -match '^docker exec cli-proxy-manager sh -c ') {
            $script:fallbackUsed = $true
            $output = @('antigravity=1', 'claude=1', 'codex=1', 'gemini=1', 'kimi=1', 'xai=1', 'all=8')
        } else {
            $exitCode = 1
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }
    function Invoke-CapabilityWebRequest {
        param([string]$Uri, [hashtable]$Headers = @{})
        $webCalls.Add($Uri) | Out-Null
        $isManagement = $Uri.Contains('/v0/management/')
        if ($isManagement -and (-not $Headers.ContainsKey('Authorization') -or -not $Headers.Authorization.StartsWith('Bearer '))) {
            throw "FAIL: protected Management API called without authentication: $Uri"
        }
        if ($Uri.EndsWith('/healthz')) {
            return [pscustomobject]@{ StatusCode = 200; Content = '{"status":"ok"}'; Headers = @{} }
        }
        if ($Uri.EndsWith('/management.html')) {
            return [pscustomobject]@{ StatusCode = 200; Content = '<html>footer.version tileValue children:`v1.20.4` private-center-content</html>'; Headers = @{} }
        }
        if ($Uri.EndsWith('/v1/models')) {
            return [pscustomobject]@{ StatusCode = 200; Content = '{"data":[{"id":"model-private-never-print"}]}'; Headers = @{} }
        }
        if ($Uri.EndsWith('/v0/management/config')) {
            return [pscustomobject]@{
                StatusCode = 200
                Content = '{"routing":{"strategy":"weighted-round-robin","session-affinity":true,"session-affinity-ttl":"45m"},"codex-api-key":[{"api-key":"config-secret-never-print","priority":9,"weight":913579}],"openai-compatibility":[{"name":"private-provider","priority":7,"api-key-entries":[{"api-key":"compat-secret-never-print","weight":765431}]}],"secret":"never-return-this"}'
                Headers = @{ 'X-CPA-VERSION' = 'v7.2.111'; 'X-CPA-COMMIT' = '4a31513'; 'X-CPA-SUPPORT-PLUGIN' = '1' }
            }
        }
        if ($Uri.EndsWith('/v0/management/auth-files')) {
            return [pscustomobject]@{
                StatusCode = 200
                Content = '{"files":[{"type":"antigravity","status":"ready","priority":1,"weight":246813,"name":"ag-private.json","email":"ag@example.test"},{"type":"claude","status":"ready","priority":2,"account_id":"account-private"},{"type":"codex","status":"ready","priority":3,"model_id":"model-private"},{"type":"gemini-cli","status":"ready","priority":4},{"type":"kimi","status":"ready","priority":5},{"type":"x-ai","status":"ready","priority":6},{"type":"futurecloud","status":"ready","priority":7},{"type":"leak@example.test","status":"ready","priority":8}]}'
                Headers = @{}
            }
        }
        if ($Uri.EndsWith('/v0/management/plugins')) {
            return [pscustomobject]@{
                StatusCode = 200
                Content = '{"plugins_enabled":true,"plugins":[{"id":"safe-plugin","configured":true,"enabled":true,"effective_enabled":true,"menus":[{},{}],"metadata":{"name":"Safe Plugin","version":"1.2.3","author":"private@example.test","config_fields":{"token":"plugin-secret-never-print"}},"path":"/private/plugin/path","external_credential":"external-secret-never-print"}]}'
                Headers = @{}
            }
        }
        if ($Uri.EndsWith('/v0/management/routing/strategy')) {
            return [pscustomobject]@{ StatusCode = 200; Content = '{"strategy":"weighted-round-robin"}'; Headers = @{} }
        }
        return [pscustomobject]@{ StatusCode = $null; Content = ''; Headers = @{} }
    }

    $probe = Get-CpaCapabilityProbe
    $data = $probe.Data
    $json = $data | ConvertTo-Json -Depth 12

    Assert-Equal $data.schema_version 1 'schema version'
    Assert-Equal $data.network.exposure_mode 'direct-public' 'exposure mode'
    Assert-Equal $data.cpa.version 'v7.2.111' 'CPA version'
    Assert-Equal $data.cpa.commit '4a315136730baa8b3a436d12b74e5a702c70be5c' 'CPA commit'
    Assert-Equal $data.release_contract.cpa_version 'v7.2.111' 'release-contract CPA version'
    Assert-Equal $data.release_contract.cpa_commit '4a315136730baa8b3a436d12b74e5a702c70be5c' 'release-contract CPA commit'
    Assert-Equal $data.release_contract.management_center_version 'v1.20.4' 'release-contract Management Center version'
    Assert-Equal $data.release_contract.management_center_commit '826ea3c0d0bdd6409a0a2703ada90faaf5aede2d' 'release-contract Management Center commit'
    Assert-Equal $data.release_contract.source 'exact_release_tags' 'release-contract source'
    Assert-Equal $data.release_contract.target_pair_compatible $true 'target-pair compatibility'
    Assert-Equal $data.release_contract.compatibility_status 'compatible' 'runtime compatibility'
    Assert-Equal $data.management_ui.enabled $true 'management UI enabled'
    Assert-Equal $data.management_ui.reachable $true 'management UI reachable'
    Assert-Equal $data.management_ui.http_status 200 'management UI HTTP status'
    Assert-Equal $data.management_ui.local_url 'http://127.0.0.1:8317/management.html' 'safe local management URL'
    Assert-Equal $data.management_ui.version 'v1.20.4' 'Management Center version'
    Assert-Equal $data.management_ui.version_source 'management_html' 'Management Center version source'
    Assert-Equal $data.management_ui.external_https_protection $null 'external HTTPS must remain unverified'
    Assert-Equal $data.management_ui.public_access_warning 'critical' 'public management warning'
    Assert-Equal $data.official_capabilities.contract_source 'live_and_audited' 'contract source'
    Assert-Equal $data.official_capabilities.management_api_available $true 'Management API support'
    Assert-Equal $data.official_capabilities.priority_write_supported $true 'priority write support'
    Assert-Equal $data.official_capabilities.quota_reset_supported $true 'quota reset support'
    Assert-Equal $data.routing.strategy 'weighted-round-robin' 'routing strategy'
    Assert-Equal $data.routing.weighted_round_robin_supported $true 'WRR support'
    Assert-Equal $data.routing.weighted_round_robin_configured $true 'WRR configured state'
    Assert-Equal $data.routing.priority_supported $true 'priority support'
    Assert-Equal $data.routing.priority_configured $true 'priority configured state'
    Assert-Equal $data.routing.credential_weights_configured $true 'credential weight configured state'
    Assert-Equal $data.routing.session_affinity_supported $true 'session-affinity support'
    Assert-Equal $data.routing.session_affinity_enabled $true 'session-affinity enabled state'
    Assert-Equal $data.routing.session_affinity_ttl '45m' 'session-affinity TTL'
    Assert-Equal $data.routing.automatic_failover_supported $true 'automatic failover support'
    Assert-Equal $data.routing.wrr_traffic_validation 'not_run' 'WRR traffic validation state'
    Assert-Equal $data.official_capabilities.plugin_system_supported $true 'plugin support'
    Assert-Equal $data.official_capabilities.plugin_system_configured $true 'plugin configured state'
    Assert-Equal $data.official_capabilities.plugin_system_enabled $true 'plugin enabled state'
    Assert-Equal $data.plugins.inspection 'available' 'plugin inspection state'
    Assert-Equal $data.plugins.count 1 'plugin count'
    Assert-Equal $data.plugins.items[0].id 'safe-plugin' 'safe plugin ID'
    Assert-Equal $data.plugins.items[0].name 'Safe Plugin' 'safe plugin name'
    Assert-Equal $data.plugins.items[0].version '1.2.3' 'plugin version'
    Assert-Equal $data.plugins.items[0].enabled $true 'plugin enabled flag'
    Assert-Equal $data.plugins.items[0].menu_count 2 'plugin menu count'
    Assert-Equal $data.security.plugin_resource_pages_management_authenticated $false 'plugin resource authentication boundary'
    Assert-Equal $data.security.critical_public_plugin_resource_exposure $true 'critical plugin resource exposure'
    Assert-Equal $data.credentials.source 'management_api' 'provider source'
    Assert-Equal $data.credentials.providers.kimi 1 'Kimi provider count'
    Assert-Equal $data.credentials.providers.xai 1 'xAI provider count'
    Assert-Equal $data.credentials.providers.unknown 1 'unknown provider count'
    Assert-Equal $data.credentials.additional_providers[0].type 'futurecloud' 'future provider type'
    Assert-Equal $data.credentials.total 8 'provider total'
    Assert-Equal $script:fallbackUsed $false 'filename fallback must not run after API success'
    Assert-True (@($data.warnings.code) -contains 'PUBLIC_PLUGIN_RESOURCES_UNAUTHENTICATED') 'critical plugin-resource warning is missing'

    foreach ($forbidden in @(
        'management-plaintext-never-print', 'management-hash-never-print', 'sk-test-secret-never-print',
        'ag-private.json', 'ag@example.test', 'private@example.test', 'account-private', 'model-private',
        '/private/plugin/path', 'plugin-secret-never-print', 'external-secret-never-print', 'never-return-this',
        'config-secret-never-print', 'compat-secret-never-print', 'private-provider',
        '913579', '765431', '246813'
    )) {
        if ($json.Contains($forbidden)) { throw "FAIL: PowerShell capability JSON exposed protected data: $forbidden" }
    }

    $script:CPA_MANAGEMENT_KEY = ''
    $script:CPA_API_KEY = ''
    $script:fallbackUsed = $false
    $webCalls.Clear()
    $noKeyProbe = Get-CpaCapabilityProbe
    $noKeyData = $noKeyProbe.Data
    Assert-True (-not (@($webCalls) | Where-Object { $_.Contains('/v0/management/') })) 'PowerShell called protected Management API without a key'
    Assert-Equal $noKeyData.plugins.reason 'management_key_unavailable' 'missing-key plugin reason'
    Assert-Equal $noKeyData.credentials.source 'filename_fallback' 'filename fallback source'
    Assert-Equal $noKeyData.credentials.providers.unknown 2 'filename fallback unknown count'
    Assert-Equal $noKeyData.routing.priority_configured $null 'missing-key priority state'
    Assert-Equal $noKeyData.routing.credential_weights_configured $null 'missing-key weight state'
    Assert-Equal $noKeyData.routing.wrr_traffic_validation 'not_run' 'missing-key WRR validation state'
    Assert-Equal $script:fallbackUsed $true 'filename fallback must run without a management key'
    Assert-Equal (Test-AuditedCpaContract 'v7.2.102' '8423cce') $true 'preserved v7.2.102 audit contract'
    Assert-Equal (Test-AuditedCpaContract 'v7.2.111' '4a31513') $true 'exact v7.2.111 audit contract'

    foreach ($call in $nativeCalls) {
        if ($call -match '^docker (pull|run|start|stop|restart|rm|create)\b' -or
            $call -match '^docker compose .*\b(up|down|pull|restart|create)\b') {
            throw "FAIL: mutating Docker call from read-only probe: $call"
        }
    }

    Write-Host 'PASS: PowerShell D2.2 release contract is exact, read-only, redacted, and no-key safe'
} finally {
    Remove-Item Env:CPA_BIND_HOST -ErrorAction SilentlyContinue
    Remove-Item Env:CPA_EXPOSURE_MODE -ErrorAction SilentlyContinue
    if (Test-Path $testDir) { Remove-Item -LiteralPath $testDir -Recurse -Force }
}
