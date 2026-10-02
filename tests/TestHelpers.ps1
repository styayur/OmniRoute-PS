Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:OmniRouteTestRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $script:OmniRouteTestRoot 'src/Version.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Logging.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Config.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Protocol.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Transport.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Adapters.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Metrics.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Health.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Router.ps1')
. (Join-Path $script:OmniRouteTestRoot 'src/Server.ps1')

function Initialize-OmniRouteTestModules {
    [CmdletBinding()]
    param()
}

function New-OmniRouteTestProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Type = 'custom-openai',
        [string]$BaseUrl = 'http://127.0.0.1:65530/v1',
        [int]$Priority = 100,
        [bool]$Enabled = $true,
        [int]$TimeoutSeconds = 5,
        [string[]]$Models = @('test-model'),
        [string]$ApiKeyEnv = '',
        [hashtable]$Headers = @{}
    )
    return @{
        id             = $Id
        type           = $Type
        baseUrl        = $BaseUrl
        apiKeyEnv      = $ApiKeyEnv
        apiKeyHeader   = if ($Type -eq 'anthropic') { 'x-api-key' } elseif ($Type -eq 'gemini') { 'x-goog-api-key' } else { 'Authorization' }
        apiKeyPrefix   = if ($Type -eq 'anthropic' -or $Type -eq 'gemini') { '' } else { 'Bearer ' }
        priority       = $Priority
        enabled        = $Enabled
        timeoutSeconds = $TimeoutSeconds
        headers        = $Headers
        models         = $Models
        healthPath     = ''
        capabilities   = @{ chat = $true; responses = $true; messages = $true; tools = $true; vision = $false; streaming = $true }
    }
}

function New-OmniRouteTestConfig {
    [CmdletBinding()]
    param(
        [hashtable]$Providers,
        [hashtable]$Routes = @{ '*' = @('primary') },
        [hashtable]$Aliases = @{},
        [int]$CircuitFailureThreshold = 3,
        [int]$CircuitOpenSeconds = 30
    )
    if (-not $PSBoundParameters.ContainsKey('Providers')) {
        $Providers = @{ primary = New-OmniRouteTestProvider -Id primary }
    }
    return @{
        sourcePath            = 'test-config'
        isExample             = $false
        listen                = '127.0.0.1'
        port                  = 20128
        requestTimeoutSeconds = 10
        maxRequestBodyBytes   = 1048576
        healthCacheSeconds    = 15
        retry                 = @{ maxAttempts = 1; baseDelayMs = 0 }
        circuitBreaker        = @{ failureThreshold = $CircuitFailureThreshold; openSeconds = $CircuitOpenSeconds; halfOpenMaxAttempts = 1 }
        fallbackOnStatus      = @(429, 500, 502, 503, 504)
        logging               = @{ level = 'information'; format = 'console' }
        server                = @{ minWorkers = 2; maxWorkers = 4; maxQueuedRequests = 16; shutdownGraceSeconds = 2 }
        http                  = @{ cors = @{ enabled = $false; allowedOrigins = @() } }
        providers             = $Providers
        routes                = $Routes
        aliases               = $Aliases
        errors                = @()
        warnings              = @()
    }
}

function Get-OmniRouteTestFreePort {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Wait-OmniRouteTestEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSeconds = 10
    )
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(1)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        while ([DateTimeOffset]::UtcNow -lt $deadline) {
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                if ($response.IsSuccessStatusCode) { return $true }
            }
            catch { }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }
    finally {
        $client.Dispose()
        if ($null -ne $response) { $response.Dispose() }
    }
}
