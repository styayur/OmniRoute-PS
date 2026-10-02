Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-OmniRouteState {
    [CmdletBinding()]
    param()
    $providers = [System.Collections.Hashtable]::Synchronized(@{})
    return @{
        startedAt      = [DateTimeOffset]::UtcNow
        providers      = $providers
        totalRequests  = 0
        activeRequests = 0
        lastRequestAt  = $null
    }
}

function Get-OmniProviderRuntimeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ProviderId
    )
    if (-not $State.providers.ContainsKey($ProviderId)) {
        $State.providers[$ProviderId] = @{
            circuitState        = 'Closed'
            consecutiveFailures = 0
            openedAt            = $null
            halfOpenAttempts    = 0
            healthy             = $null
            latencyMs           = $null
            movingAverageMs     = $null
            lastCheckedAt       = $null
            lastError           = $null
            requests            = 0
            failures            = 0
        }
    }
    return $State.providers[$ProviderId]
}

function Get-OmniCircuitState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][hashtable]$Config
    )
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
        if ($runtime.circuitState -eq 'Open' -and $null -ne $runtime.openedAt) {
            $openSeconds = [int]$Config.circuitBreaker.openSeconds
            if (([DateTimeOffset]::UtcNow - [DateTimeOffset]$runtime.openedAt).TotalSeconds -ge $openSeconds) {
                $runtime.circuitState = 'HalfOpen'
                $runtime.halfOpenAttempts = 0
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
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
        if ($runtime.circuitState -eq 'Open' -and $null -ne $runtime.openedAt) {
            $openSeconds = [int]$Config.circuitBreaker.openSeconds
            if (([DateTimeOffset]::UtcNow - [DateTimeOffset]$runtime.openedAt).TotalSeconds -ge $openSeconds) {
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

function Set-OmniProviderSuccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][int]$LatencyMs
    )
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
        $runtime.circuitState = 'Closed'
        $runtime.consecutiveFailures = 0
        $runtime.openedAt = $null
        $runtime.halfOpenAttempts = 0
        $runtime.healthy = $true
        $runtime.latencyMs = $LatencyMs
        $runtime.movingAverageMs = if ($null -eq $runtime.movingAverageMs) { $LatencyMs } else { [int](0.8 * $runtime.movingAverageMs + 0.2 * $LatencyMs) }
        $runtime.lastCheckedAt = [DateTimeOffset]::UtcNow
        $runtime.lastError = $null
        $runtime.requests++
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
    [System.Threading.Monitor]::Enter($State.providers)
    try {
        $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
        $runtime.requests++
        $runtime.failures++
        $runtime.consecutiveFailures++
        $runtime.healthy = $false
        $runtime.lastCheckedAt = [DateTimeOffset]::UtcNow
        $runtime.lastError = if ($null -eq $Failure) { 'Unknown provider failure.' } else { [string]$Failure.message }
        if ($runtime.circuitState -eq 'HalfOpen') {
            $runtime.circuitState = 'Open'
            $runtime.openedAt = [DateTimeOffset]::UtcNow
            $runtime.halfOpenAttempts = 0
        }
        elseif ($runtime.consecutiveFailures -ge [int]$Config.circuitBreaker.failureThreshold) {
            $runtime.circuitState = 'Open'
            $runtime.openedAt = [DateTimeOffset]::UtcNow
            $runtime.halfOpenAttempts = 0
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
    if ($runtime.healthy -eq $true) { return 0 }
    if ($runtime.healthy -eq $false) { return 30 }
    return 0
}

function Get-OmniRouteHealthReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State
    )

    $providerReport = [ordered]@{}
    $healthyCount = 0
    $unhealthyCount = 0
    $availableCount = 0
    foreach ($providerId in @($Config.providers.Keys)) {
        $provider = $Config.providers[$providerId]
        if (-not $provider.enabled) {
            $providerReport[$providerId] = [ordered]@{ state = 'disabled'; latencyMs = $null; circuitState = 'Disabled'; consecutiveFailures = 0 }
            continue
        }
        $availableCount++
        $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $providerId
        $circuit = Get-OmniCircuitState -State $State -Provider $provider -Config $Config
        $providerState = if ($runtime.healthy -eq $true) { 'healthy' } elseif ($runtime.healthy -eq $false) { 'unhealthy' } else { 'unknown' }
        if ($runtime.healthy -eq $true) { $healthyCount++ }
        elseif ($runtime.healthy -eq $false) { $unhealthyCount++ }
        $providerReport[$providerId] = [ordered]@{
            state               = $providerState
            latencyMs           = $runtime.latencyMs
            circuitState        = $circuit
            consecutiveFailures = $runtime.consecutiveFailures
            lastCheckedAt       = if ($null -eq $runtime.lastCheckedAt) { $null } else { ([DateTimeOffset]$runtime.lastCheckedAt).ToString('o') }
            lastError           = if ([string]::IsNullOrWhiteSpace([string]$runtime.lastError)) { $null } else { ConvertTo-OmniRouteRedactedText -Text ([string]$runtime.lastError) }
        }
    }
    $overall = if ($unhealthyCount -gt 0 -and $healthyCount -eq 0) { 'degraded' } else { 'ok' }
    if ($State.providers.Count -eq 0) { $overall = 'ok' }
    return [ordered]@{
        status    = $overall
        version   = '0.1.0'
        uptimeSec = [int]([DateTimeOffset]::UtcNow - $State.startedAt).TotalSeconds
        providers = $providerReport
    }
}