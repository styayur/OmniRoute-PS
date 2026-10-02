#!/usr/bin/env pwsh
#requires -Version 7.4

param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Subcommand,

    [Alias('Config')]
    [string]$ConfigPath,

    [Alias('Host')]
    [string]$BindHost,

    [int]$Port = 0,

    [switch]$Json,

    [ValidateSet('console', 'json')]
    [string]$LogFormat = 'console',


    [switch]$Live
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'src/Version.ps1')
$script:OmniRouteVersion = Get-OmniRouteVersion
$debugEnabled = $PSBoundParameters.ContainsKey('Debug') -or $DebugPreference -ne 'SilentlyContinue'
$script:OmniRouteRoot = $PSScriptRoot

if ($Command -eq 'config' -and $Subcommand -eq 'schema') {
    $schemaPath = Join-Path $PSScriptRoot 'schemas/omniroute.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw "Schema file not found: $schemaPath" }
    if ($Json) { Get-Content -LiteralPath $schemaPath -Raw } else { $schemaPath }
    exit 0
}
if ($Command -eq 'version') {
    $versionResult = [pscustomobject]@{
        name     = 'OmniRoute-PS'
        version  = $script:OmniRouteVersion
        runtime  = $PSVersionTable.PSVersion.ToString()
        platform = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    }
    if ($Json) { $versionResult | ConvertTo-Json -Depth 10 } else { $versionResult | Format-List }
    exit 0
}

. (Join-Path $PSScriptRoot 'src/Logging.ps1')
. (Join-Path $PSScriptRoot 'src/Config.ps1')
. (Join-Path $PSScriptRoot 'src/Protocol.ps1')
. (Join-Path $PSScriptRoot 'src/Transport.ps1')
. (Join-Path $PSScriptRoot 'src/Adapters.ps1')
. (Join-Path $PSScriptRoot 'src/Metrics.ps1')
. (Join-Path $PSScriptRoot 'src/Health.ps1')
. (Join-Path $PSScriptRoot 'src/Router.ps1')
. (Join-Path $PSScriptRoot 'src/Server.ps1')

function Write-OmniRouteCliOutput {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [switch]$AsJson,
        [string]$TableProperty = ''
    )
    if ($AsJson) {
        $Value | ConvertTo-Json -Depth 30
        return
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        $Value | Format-List
    }
    elseif ($TableProperty) {
        $Value | Format-Table -Property $TableProperty -AutoSize
    }
    else {
        $Value | Format-Table -AutoSize
    }
}

function Show-OmniRouteHelp {
    @(
        ("OmniRoute-PS $script:OmniRouteVersion")
        ''
        'Usage:'
        '  pwsh ./omniroute.ps1 <command> [options]'
        ''
        'Commands:'
        '  serve       Start the local OpenAI-compatible router.'
        '  status      Query a running router and report service health.'
        '  models      List configured model IDs and aliases.'
        '  providers   List configured providers and safe metadata.'
        '  test        Validate configuration; use -Live to probe providers.'
        '  check       Validate configuration and report warnings.'
        '  config      config schema | config validate'
        '  version     Print the version.'
        '  help        Show this help.'
        ''
        'Options:'
        '  -Config <path>       JSON config path (default: omniroute.json, then omniroute.example.json).'
        '  -Host <address>      Override the configured listen address.'
        '  -Port <number>       Override the configured port.'
        '  -Json                Emit machine-readable JSON.'
        '  -LogFormat <value>   console or json.'
        '  -Debug               Show detailed internal errors on stderr.'
        '  -Live                Allow test to make network requests.'
    ) -join "`n"
}

function Invoke-OmniRouteStatusRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [int]$TimeoutSeconds = 3
    )
    $client = Get-OmniRouteHttpClient
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $response = $null
    try {
        $response = $client.GetAsync($Endpoint, $cts.Token).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync($cts.Token).GetAwaiter().GetResult()
        return [pscustomobject]@{
            running    = $true
            statusCode = [int]$response.StatusCode
            body       = $content
            error      = $null
        }
    }
    catch {
        return [pscustomobject]@{
            running    = $false
            statusCode = 0
            body       = ''
            error      = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $cts.Dispose()
    }
}

function Get-OmniRouteConfiguredModel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    return Get-OmniRouteModelsResponse -Config $Config
}

function Get-OmniRouteProviderSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [AllowNull()][object]$HealthReport = $null
    )
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($providerId in @($Config.providers.Keys)) {
        $provider = $Config.providers[$providerId]
        $keyConfigured = if ([string]::IsNullOrWhiteSpace([string]$provider.apiKeyEnv)) { $null } else { -not [string]::IsNullOrEmpty((Get-OmniRouteApiKey -Provider $provider)) }
        $health = if ($null -ne $HealthReport -and $HealthReport.providers.Contains($providerId)) { $HealthReport.providers[$providerId] } else { $null }
        $items.Add([pscustomobject]@{
            id            = $provider.id
            type          = $provider.type
            enabled       = $provider.enabled
            priority      = $provider.priority
            baseUrl       = $provider.baseUrl
            apiKeyEnv     = if ([string]::IsNullOrWhiteSpace($provider.apiKeyEnv)) { $null } else { $provider.apiKeyEnv }
            apiKeyPresent = $keyConfigured
            models        = @($provider.models)
            circuitState  = if ($null -eq $health) { 'unknown' } else { $health.circuitState }
            health        = if ($null -eq $health) { 'unknown' } else { $health.state }
            latencyMs     = if ($null -eq $health) { $null } else { $health.latencyMs }
            capabilities  = $provider.capabilities
        })
    }
    return @($items)
}

$configResult = Test-OmniRouteConfig -Path $ConfigPath -BasePath $script:OmniRouteRoot

if ($Command -in @('help', '--help', '-h')) {
    Show-OmniRouteHelp
    exit 0
}


if (-not $configResult.valid) {
    if ($Json) {
        [pscustomobject]@{
            valid      = $false
            sourcePath = $configResult.sourcePath
            errors     = @($configResult.errors)
            warnings   = @($configResult.warnings)
        } | ConvertTo-Json -Depth 20
    }
    else {
        Write-Host "Configuration is invalid: $($configResult.sourcePath)" -ForegroundColor Red
        foreach ($issue in @($configResult.errors)) { Write-Host "  ERROR $($issue.path): $($issue.message)" -ForegroundColor Red }
    }
    exit 1
}

$config = $configResult.config
if ($PSBoundParameters.ContainsKey('BindHost') -and -not [string]::IsNullOrWhiteSpace($BindHost)) { $config.listen = $BindHost }
if ($PSBoundParameters.ContainsKey('Port') -and $Port -gt 0) { $config.port = $Port }
if ($PSBoundParameters.ContainsKey('LogFormat')) { $config.logging.format = $LogFormat }
if ($debugEnabled) { $config.logging.level = 'debug' }

if ($Command -eq 'config' -and $Subcommand -eq 'validate') { $Command = 'check' }

switch ($Command.ToLowerInvariant()) {
    'serve' {
        Write-Host "OmniRoute-PS $script:OmniRouteVersion" -ForegroundColor Cyan
        if ($config.isExample) {
            Write-Host 'Using omniroute.example.json. Copy it to omniroute.json and configure your providers.' -ForegroundColor Yellow
        }
        foreach ($warning in @($configResult.warnings)) {
            Write-Host "WARN $($warning.path): $($warning.message)" -ForegroundColor Yellow
        }
        Start-OmniRouteServer -Config $config -ConfigPath $configResult.sourcePath -DebugMode $debugEnabled
    }
    'status' {
        $endpoint = "http://127.0.0.1:$($config.port)"
        $health = Invoke-OmniRouteStatusRequest -Endpoint "$endpoint/health"
        $payload = [pscustomobject]@{
            running    = $health.running
            endpoint   = $endpoint
            statusCode = $health.statusCode
            health     = if ($health.running -and $health.statusCode -eq 200) { $health.body | ConvertFrom-Json -AsHashtable } else { $null }
            error      = $health.error
        }
        Write-OmniRouteCliOutput -Value $payload -AsJson:$Json
    }
    'models' {
        $payload = Get-OmniRouteConfiguredModel -Config $config
        Write-OmniRouteCliOutput -Value $payload -AsJson:$Json
    }
    'providers' {
        $healthReport = $null
        $health = Invoke-OmniRouteStatusRequest -Endpoint "http://127.0.0.1:$($config.port)/health"
        if ($health.running -and $health.statusCode -eq 200) {
            try { $healthReport = $health.body | ConvertFrom-Json -AsHashtable } catch { $healthReport = $null }
        }
        $payload = Get-OmniRouteProviderSummary -Config $config -HealthReport $healthReport
        Write-OmniRouteCliOutput -Value $payload -AsJson:$Json -TableProperty 'id,type,enabled,priority,apiKeyPresent,health,circuitState,latencyMs'
    }
    'check' {
        $payload = [pscustomobject]@{
            valid      = $configResult.valid
            sourcePath = $configResult.sourcePath
            errors     = @($configResult.errors)
            warnings   = @($configResult.warnings)
            providers  = $config.providers.Count
            routes     = $config.routes.Count
            aliases    = $config.aliases.Count
        }
        Write-OmniRouteCliOutput -Value $payload -AsJson:$Json
    }
    'test' {
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($providerId in @($config.providers.Keys)) {
            $provider = $config.providers[$providerId]
            if (-not $provider.enabled) {
                $results.Add([pscustomobject]@{ id = $providerId; enabled = $false; success = $null; status = $null; latencyMs = $null; error = 'disabled' })
                continue
            }
            if (-not $Live) {
                $results.Add([pscustomobject]@{ id = $providerId; enabled = $true; success = $null; status = $null; latencyMs = $null; error = 'not probed; use -Live' })
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$provider.apiKeyEnv) -and [string]::IsNullOrEmpty((Get-OmniRouteApiKey -Provider $provider))) {
                $results.Add([pscustomobject]@{ id = $providerId; enabled = $true; success = $false; status = $null; latencyMs = $null; error = "missing environment variable $($provider.apiKeyEnv)" })
                continue
            }
            $probeUri = Get-OmniRouteProviderProbeUri -Provider $provider
            $probe = Invoke-OmniRouteUpstreamProbe -Uri $probeUri -Headers (Get-OmniRouteProviderHeaders -Provider $provider) -TimeoutSeconds 10
            $results.Add([pscustomobject]@{
                id        = $providerId
                enabled   = $true
                success   = [bool]$probe.success
                status    = $probe.status
                latencyMs = $probe.latencyMs
                error     = if ($null -eq $probe.error) { $null } else { $probe.error.message }
            })
        }
        $payload = [pscustomobject]@{
            valid      = $configResult.valid
            sourcePath = $configResult.sourcePath
            live       = [bool]$Live
            providers  = @($results)
        }
        Write-OmniRouteCliOutput -Value $payload -AsJson:$Json
        if ($Live -and @($results | Where-Object { $_.success -eq $false }).Count -gt 0) { exit 1 }
    }
    default {
        Write-Host "Unknown command '$Command'." -ForegroundColor Red
        Show-OmniRouteHelp
        exit 1
    }
}
