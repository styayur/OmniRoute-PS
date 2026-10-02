Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-OmniRouteState {
    [CmdletBinding()]
    param()
    return @{
        startedAt      = [DateTimeOffset]::UtcNow
        providers      = [System.Collections.Hashtable]::Synchronized(@{})
        metrics        = [System.Collections.Hashtable]::Synchronized(@{})
        config         = [System.Collections.Hashtable]::Synchronized(@{})
        workers        = [System.Collections.Hashtable]::Synchronized(@{ active = 0; available = 0; queued = 0 })
        initialized    = $false
        shuttingDown   = $false
        configRevision = 0
    }
}

function Get-OmniProviderRuntimeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ProviderId
    )
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        if (-not $State.providers.ContainsKey($ProviderId)) {
            $State.providers[$ProviderId] = @{
                availability        = 'unknown'
                circuitState        = 'Closed'
                consecutiveFailures = 0
                openedAt            = $null
                halfOpenAttempts    = 0
                healthy             = $null
                latencyMs           = $null
                movingAverageMs     = $null
                latencySamples      = 0
                lastCheckedAt       = $null
                lastSuccessAt       = $null
                lastFailureAt       = $null
                recentErrorClass    = $null
                rateLimitedUntil    = $null
                consecutive429      = 0
                requests            = 0
                failures            = 0
                modelErrors         = [System.Collections.Hashtable]::Synchronized(@{})
            }
        }
        return $State.providers[$ProviderId]
    }
    finally {
        [System.Threading.Monitor]::Exit($State.providers)
    }
}

function Get-OmniCircuitState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][hashtable]$Config
    )
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        if ($runtime.circuitState -eq 'Open' -and $null -ne $runtime.openedAt) {
            if (([DateTimeOffset]::UtcNow - [DateTimeOffset]$runtime.openedAt).TotalSeconds -ge [int]$Config.circuitBreaker.openSeconds) {
                $runtime.circuitState = 'HalfOpen'
                $runtime.halfOpenAttempts = 0
                $runtime.availability = 'degraded'
            }
        }
        return [string]$runtime.circuitState
    }
    finally {
        [System.Threading.Monitor]::Exit($State.providers)
    }
}

function Test-OmniCircuitAllowsRequest {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][hashtable]$Config
    )
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        if ($runtime.circuitState -eq 'Open' -and $null -ne $runtime.openedAt) {
            if (([DateTimeOffset]::UtcNow - [DateTimeOffset]$runtime.openedAt).TotalSeconds -ge [int]$Config.circuitBreaker.openSeconds) {
                $runtime.circuitState = 'HalfOpen'
                $runtime.halfOpenAttempts = 0
            }
        }
        if ($runtime.circuitState -eq 'Open') { return $false }
        if ($runtime.circuitState -eq 'HalfOpen') {
            if ($runtime.halfOpenAttempts -ge [int]$Config.circuitBreaker.halfOpenMaxAttempts) { return $false }
            $runtime.halfOpenAttempts++
        }
        return $true
    }
    finally {
        [System.Threading.Monitor]::Exit($State.providers)
    }
}

function Get-OmniRouteErrorClass {
    [CmdletBinding()]
    [OutputType([string])]
    param([Alias('Error')]
        [AllowNull()][object]$Failure)
    if ($null -eq $Failure) { return 'unknown' }
    $code = [string]$Failure.code
    $status = [int]$Failure.status
    $message = [string]$Failure.message
    if ($code -eq 'upstream_timeout') { return 'timeout' }
    if ($code -eq 'upstream_connection_failed') {
        if ($message -match '(?i)(dns|name or service|host)') { return 'dns_failure' }
        return 'connection_failure'
    }
    if ($code -eq 'malformed_upstream_response') { return 'malformed_upstream' }
    if ($code -in @('upstream_stream_error', 'upstream_transport_error')) { return 'connection_failure' }
    if ($status -eq 429 -or $code -eq 'upstream_rate_limit') { return 'rate_limit' }
    if ($status -in @(401, 403) -or $code -eq 'upstream_authentication_error') { return 'authentication' }
    if ($status -eq 404 -or $message -match '(?i)(model.{0,20}(not found|unknown|unsupported)|does not exist)') { return 'model_not_found' }
    if ($status -in @(400, 422) -or $code -eq 'invalid_request') { return 'invalid_request' }
    if ($code -eq 'unsupported_feature' -or $message -match '(?i)unsupported') { return 'unsupported_feature' }
    if ($status -in @(502, 503, 504)) { return 'upstream_unavailable' }
    if ($status -eq 500) { return 'upstream_error' }
    return 'unknown'
}

function Test-OmniRouteCircuitError {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ErrorClass)
    return $ErrorClass -in @('timeout', 'connection_failure', 'dns_failure', 'upstream_unavailable', 'malformed_upstream')
}

function Set-OmniProviderSuccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][int]$LatencyMs
    )
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        $runtime.availability = 'available'
        $runtime.circuitState = 'Closed'
        $runtime.consecutiveFailures = 0
        $runtime.openedAt = $null
        $runtime.halfOpenAttempts = 0
        $runtime.healthy = $true
        $runtime.latencyMs = $LatencyMs
        $runtime.latencySamples++
        $runtime.movingAverageMs = if ($null -eq $runtime.movingAverageMs) { $LatencyMs } else { [int](0.8 * $runtime.movingAverageMs + 0.2 * $LatencyMs) }
        $runtime.lastCheckedAt = [DateTimeOffset]::UtcNow
        $runtime.lastSuccessAt = [DateTimeOffset]::UtcNow
        $runtime.recentErrorClass = $null
        $runtime.requests++
        $runtime.failures = 0
        $runtime.consecutive429 = 0
        $runtime.rateLimitedUntil = $null
    }
    finally {
        [System.Threading.Monitor]::Exit($State.providers)
    }
}

function Set-OmniProviderFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][hashtable]$Config,
        [Alias('Error')]
        [AllowNull()][object]$Failure
    )
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    $errorClass = Get-OmniRouteErrorClass -Error $Failure
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        $runtime.requests++
        $runtime.failures++
        $runtime.lastCheckedAt = [DateTimeOffset]::UtcNow
        $runtime.lastFailureAt = [DateTimeOffset]::UtcNow
        $runtime.recentErrorClass = $errorClass
        switch ($errorClass) {
            'rate_limit' {
                $runtime.availability = 'rate_limited'
                $runtime.consecutive429++
                $runtime.rateLimitedUntil = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max(1, [int]$Config.circuitBreaker.openSeconds / 2))
            }
            'authentication' {
                $runtime.availability = 'auth_error'
                $runtime.healthy = $false
            }
            'model_not_found' {
                $model = if ($Failure -is [System.Collections.IDictionary]) { [string](Get-OmniRouteDictValue -Dictionary $Failure -Name 'model' -Default '') } elseif ($null -ne $Failure.PSObject.Properties['model']) { [string]$Failure.model } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($model)) { $runtime.modelErrors[$model] = [DateTimeOffset]::UtcNow }
            }
            'invalid_request' { }
            'unsupported_feature' { }
            default {
                $runtime.consecutiveFailures++
                $runtime.healthy = $false
                $runtime.availability = 'degraded'
                if ($runtime.circuitState -eq 'HalfOpen' -and (Test-OmniRouteCircuitError -ErrorClass $errorClass)) {
                    $runtime.circuitState = 'Open'
                    $runtime.openedAt = [DateTimeOffset]::UtcNow
                    $runtime.halfOpenAttempts = 0
                    Add-OmniRouteMetric -State $State -Name 'omniroute_circuit_open_total'
                }
                elseif ($runtime.consecutiveFailures -ge [int]$Config.circuitBreaker.failureThreshold -and (Test-OmniRouteCircuitError -ErrorClass $errorClass)) {
                    $runtime.circuitState = 'Open'
                    $runtime.openedAt = [DateTimeOffset]::UtcNow
                    $runtime.halfOpenAttempts = 0
                    Add-OmniRouteMetric -State $State -Name 'omniroute_circuit_open_total'
                }
            }
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($State.providers)
    }
}

function Get-OmniRouteHealthPenalty {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Provider)
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    if ($runtime.availability -eq 'available') { return 0 }
    if ($runtime.availability -eq 'rate_limited') { return 10 }
    if ($runtime.availability -eq 'auth_error') { return 100 }
    if ($runtime.availability -eq 'degraded') { return 30 }
    return 0
}

function Get-OmniRouteRateLimitPenalty {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Provider)
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    if ($null -eq $runtime.rateLimitedUntil) { return 0 }
    if ([DateTimeOffset]::UtcNow -lt [DateTimeOffset]$runtime.rateLimitedUntil) { return [Math]::Min(100, 20 + ($runtime.consecutive429 * 10)) }
    return 0
}

function Test-OmniProviderModelCompatible {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Model
    )
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    if (-not $runtime.modelErrors.ContainsKey($Model)) { return $true }
    return (([DateTimeOffset]::UtcNow - [DateTimeOffset]$runtime.modelErrors[$Model]).TotalSeconds -gt 60)
}

function Get-OmniRouteReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not $State.initialized) { $reasons.Add('router_not_initialized') }
    if ($State.shuttingDown) { $reasons.Add('shutting_down') }
    $available = 0
    foreach ($providerId in @($Config.providers.Keys)) {
        $provider = $Config.providers[$providerId]
        if (-not $provider.enabled) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$provider.apiKeyEnv) -and [string]::IsNullOrEmpty((Get-OmniRouteApiKey -Provider $provider))) { continue }
        $circuit = Get-OmniCircuitState -State $State -Provider $provider -Config $Config
        if ($circuit -ne 'Open') { $available++ }
    }
    if ($available -eq 0) { $reasons.Add('no_available_provider') }
    return [pscustomobject]@{ ready = ($reasons.Count -eq 0); reasons = @($reasons); availableProviders = $available }
}

function Get-OmniRouteHealthReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()][object]$WorkerSnapshot = $null
    )
    $providerReport = [ordered]@{}
    $healthyCount = 0
    $unhealthyCount = 0
    foreach ($providerId in @($Config.providers.Keys)) {
        $provider = $Config.providers[$providerId]
        if (-not $provider.enabled) {
            $providerReport[$providerId] = [ordered]@{ state = 'disabled'; availability = 'disabled'; latencyMs = $null; circuitState = 'Disabled'; consecutiveFailures = 0 }
            continue
        }
        $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $providerId
        $circuit = Get-OmniCircuitState -State $State -Provider $provider -Config $Config
        if ($runtime.availability -eq 'available') { $healthyCount++ } elseif ($runtime.availability -in @('degraded', 'auth_error')) { $unhealthyCount++ }
        $providerReport[$providerId] = [ordered]@{
            state               = $runtime.availability
            availability        = $runtime.availability
            latencyMs           = $runtime.latencyMs
            movingAverageMs     = $runtime.movingAverageMs
            rateLimitedUntil    = if ($null -eq $runtime.rateLimitedUntil) { $null } else { ([DateTimeOffset]$runtime.rateLimitedUntil).ToString('o') }
            circuitState        = $circuit
            consecutiveFailures = $runtime.consecutiveFailures
            recentErrorClass    = $runtime.recentErrorClass
            lastSuccessAt       = if ($null -eq $runtime.lastSuccessAt) { $null } else { ([DateTimeOffset]$runtime.lastSuccessAt).ToString('o') }
            lastFailureAt       = if ($null -eq $runtime.lastFailureAt) { $null } else { ([DateTimeOffset]$runtime.lastFailureAt).ToString('o') }
            lastCheckedAt       = if ($null -eq $runtime.lastCheckedAt) { $null } else { ([DateTimeOffset]$runtime.lastCheckedAt).ToString('o') }
            capabilities        = $provider.capabilities
        }
    }
    $readiness = Get-OmniRouteReadiness -Config $Config -State $State
    $overall = if (-not $readiness.ready) { 'degraded' } elseif ($unhealthyCount -gt 0 -and $healthyCount -eq 0) { 'degraded' } else { 'ok' }
    $result = [ordered]@{
        status          = $overall
        ready           = [bool]$readiness.ready
        version         = Get-OmniRouteVersion
        uptimeSec       = [int]([DateTimeOffset]::UtcNow - $State.startedAt).TotalSeconds
        configRevision  = [int]$State.configRevision
        providers       = $providerReport
    }
    if ($null -ne $WorkerSnapshot) { $result.workers = $WorkerSnapshot }
    return $result
}
