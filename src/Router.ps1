Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-OmniRouteRequestId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function New-OmniRouteErrorResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Status,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [string]$RequestId = (New-OmniRouteRequestId),
        [AllowNull()][object]$Attempts = $null,
        [AllowNull()][string]$Provider = $null,
        [AllowNull()][string]$Model = $null,
        [int]$LatencyMs = 0,
        [switch]$RetryAfter
    )
    $errorObject = [ordered]@{ message = ConvertTo-OmniRouteRedactedText -Text $Message; type = $Type; code = $Code }
    if ($null -ne $Attempts) { $errorObject.attempts = $Attempts }
    $json = @{ error = $errorObject } | ConvertTo-Json -Depth 20 -Compress
    return [pscustomobject]@{
        success     = $false
        statusCode  = $Status
        body        = $json
        contentType = 'application/json; charset=utf-8'
        requestId   = $RequestId
        provider    = $Provider
        model       = $Model
        latencyMs   = $LatencyMs
        attempts    = $Attempts
        stream      = $false
        retryAfter  = [bool]$RetryAfter
    }
}

function Resolve-OmniRouteModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Model
    )
    $resolved = $Model
    if ($Config.aliases.Contains($resolved)) { $resolved = [string]$Config.aliases[$resolved] }
    $forcedProvider = $null
    $bestLength = -1
    foreach ($providerId in @($Config.providers.Keys)) {
        $prefix = "$providerId`:"
        if ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $providerId.Length -gt $bestLength) {
            $forcedProvider = $providerId
            $bestLength = $providerId.Length
        }
    }
    if ($null -ne $forcedProvider) { $resolved = $resolved.Substring($forcedProvider.Length + 1) }

    $routePattern = $null
    $routeProviders = @()
    $bestScore = -1
    foreach ($pattern in @($Config.routes.Keys)) {
        $patternText = [string]$pattern
        $wildcard = [System.Management.Automation.WildcardPattern]::new($patternText, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        if (-not $wildcard.IsMatch($resolved)) { continue }
        $score = 1000 + ($patternText -replace '[*?\[\]]', '').Length
        if ($patternText -notmatch '[*?\[\]]') { $score += 10000 }
        elseif ($patternText.EndsWith('*') -and @($patternText.ToCharArray() | Where-Object { $_ -eq '*' }).Count -eq 1) { $score += 5000 }
        if ($score -gt $bestScore) { $bestScore = $score; $routePattern = $patternText; $routeProviders = @($Config.routes[$pattern]) }
    }
    return [pscustomobject]@{ originalModel = $Model; model = $resolved; forcedProvider = $forcedProvider; routePattern = $routePattern; routeProviders = $routeProviders }
}

function Get-OmniRouteCapabilityRequirement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Request)
    $requiresTools = @(Get-OmniRouteDictValue -Dictionary $Request -Name 'tools' -Default @()).Count -gt 0
    $requiresVision = $false
    foreach ($message in @(Get-OmniRouteDictValue -Dictionary $Request -Name 'messages' -Default @())) {
        foreach ($part in @($message.content)) {
            if ([string]$part.type -eq 'image') { $requiresVision = $true }
        }
    }
    $protocolKey = switch ([string]$Request.protocol) {
        'openai-chat' { 'chat' }
        'openai-responses' { 'responses' }
        'anthropic-messages' { 'messages' }
        default { 'chat' }
    }
    return @{ protocol = $protocolKey; tools = $requiresTools; vision = $requiresVision; streaming = [bool]$Request.stream }
}

function Test-OmniRouteProviderCapabilities {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][hashtable]$Requirement
    )
    if ($null -eq $Provider.capabilities) { return $true }
    if (-not [bool]$Provider.capabilities[$Requirement.protocol]) { return $false }
    if ($Requirement.tools -and -not [bool]$Provider.capabilities.tools) { return $false }
    if ($Requirement.vision -and -not [bool]$Provider.capabilities.vision) { return $false }
    if ($Requirement.streaming -and -not [bool]$Provider.capabilities.streaming) { return $false }
    return $true
}

function Test-OmniRouteProviderUsable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][hashtable]$Requirement,
        [Parameter(Mandatory)][string]$Model
    )
    if (-not $Provider.enabled) { return $false }
    if (-not (Test-OmniRouteProviderCapabilities -Provider $Provider -Requirement $Requirement)) { return $false }
    if (-not (Test-OmniProviderModelCompatible -State $State -Provider $Provider -Model $Model)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$Provider.apiKeyEnv) -and [string]::IsNullOrEmpty((Get-OmniRouteApiKey -Provider $Provider))) { return $false }
    $circuit = Get-OmniCircuitState -State $State -Provider $Provider -Config $Config
    if ($circuit -eq 'Open') { return $false }
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    if ($runtime.availability -eq 'auth_error') { return $false }
    if ($runtime.healthy -eq $false -and $null -ne $runtime.lastCheckedAt) {
        $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$runtime.lastCheckedAt).TotalSeconds
        if ($age -le [int]$Config.healthCacheSeconds) { return $false }
    }
    return $true
}

function Get-OmniRouteProviderScore {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Provider)
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    $failurePenalty = [int]$runtime.consecutiveFailures * 20
    $latencyPenalty = if ($null -eq $runtime.movingAverageMs) { 0 } else { [double]$runtime.movingAverageMs / 100.0 }
    $healthPenalty = Get-OmniRouteHealthPenalty -State $State -Provider $Provider
    $rateLimitPenalty = Get-OmniRouteRateLimitPenalty -State $State -Provider $Provider
    return [double]$Provider.priority - $failurePenalty - $latencyPenalty - $healthPenalty - $rateLimitPenalty
}

function Get-OmniRouteCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][object]$Route,
        [Parameter(Mandatory)][hashtable]$Requirement
    )
    $providerIds = if ($null -ne $Route.forcedProvider) { @([string]$Route.forcedProvider) } else { @($Route.routeProviders) }
    $candidates = [System.Collections.Generic.List[object]]::new()
    $order = 0
    foreach ($providerId in $providerIds) {
        $provider = Get-OmniRouteProvider -Config $Config -Id $providerId
        if ($null -eq $provider) { continue }
        if (-not (Test-OmniRouteProviderUsable -Config $Config -State $State -Provider $provider -Requirement $Requirement -Model $Route.model)) { continue }
        $candidates.Add([pscustomobject]@{ provider = $provider; score = Get-OmniRouteProviderScore -State $State -Provider $provider; order = $order })
        $order++
    }
    return @($candidates | Sort-Object -Property @{ Expression = { [double]$_.score }; Descending = $true }, @{ Expression = { [int]$_.order }; Descending = $false })
}

function Test-OmniRouteFallback {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Config, [AllowNull()][object]$Failure)
    if ($null -eq $Failure) { return $false }
    $errorClass = Get-OmniRouteErrorClass -Error $Failure
    if ($errorClass -in @('timeout', 'connection_failure', 'dns_failure', 'malformed_upstream', 'rate_limit', 'upstream_unavailable', 'upstream_error')) { return $true }
    return ([int]$Failure.status -in @($Config.fallbackOnStatus))
}

function ConvertTo-OmniRouteAttemptLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][int]$Status,
        [Parameter(Mandatory)][int]$LatencyMs,
        [AllowNull()][string]$FallbackReason
    )
    return @{ req = $RequestId; model = $Model; attempt = $Attempt; provider = $Provider.id; status = $Status; latencyMs = $LatencyMs; fallbackReason = $FallbackReason }
}

function Invoke-OmniRouteRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Request,
        [Parameter(Mandatory)][ValidateSet('openai-chat', 'openai-responses', 'anthropic-messages')][string]$InboundProtocol,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [string]$RequestId = (New-OmniRouteRequestId)
    )

    $route = Resolve-OmniRouteModel -Config $Config -Model ([string]$Request.model)
    $canonicalRequest = @{}
    foreach ($key in $Request.Keys) { $canonicalRequest[$key] = $Request[$key] }
    $canonicalRequest.model = $route.model
    $requirement = Get-OmniRouteCapabilityRequirement -Request $canonicalRequest
    if ([string]::IsNullOrWhiteSpace($route.model)) {
        return New-OmniRouteErrorResult -Status 400 -Type 'routing_error' -Code 'missing_model' -Message "Request field 'model' is required." -RequestId $RequestId
    }
    $candidates = Get-OmniRouteCandidates -Config $Config -State $State -Route $route -Requirement $requirement
    if (@($candidates).Count -eq 0) {
        return New-OmniRouteErrorResult -Status 503 -Type 'routing_error' -Code 'no_provider' -Message "No capable provider available for model '$($route.originalModel)'." -RequestId $RequestId -Model $route.model
    }

    $attemptLogs = [System.Collections.Generic.List[object]]::new()
    $lastError = $null
    $attempt = 0
    $canonicalRequestWatch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($candidate in $candidates) {
        $attempt++
        $provider = $candidate.provider
        Add-OmniRouteMetric -State $State -Name 'omniroute_provider_requests_total' -Labels @{ provider = $provider.id }
        $providerRequestBody = ConvertFrom-OmniRouteCanonicalRequest -Request $canonicalRequest -Provider $provider
        $endpointUri = Get-OmniRouteProviderEndpoint -Provider $provider -Model $route.model -Stream $false
        $headers = Get-OmniRouteProviderHeaders -Provider $provider
        $result = Invoke-OmniRouteUpstreamRequest -Provider $provider -Method 'POST' -Uri $endpointUri -Headers $headers -Body $providerRequestBody -Retry $Config.retry -CancellationToken $CancellationToken
        if ($result.success) {
            try {
                $canonicalResponse = ConvertTo-OmniRouteCanonicalResponse -Provider $provider -Content $result.content -Model $route.model
                $clientResponse = ConvertFrom-OmniRouteCanonicalResponse -Response $canonicalResponse -Protocol $InboundProtocol
                Set-OmniProviderSuccess -State $State -Provider $provider -LatencyMs $result.latencyMs
                Add-OmniRouteMetric -State $State -Name 'omniroute_request_duration_ms_sum' -Value ([long]$canonicalRequestWatch.ElapsedMilliseconds)
                Add-OmniRouteMetric -State $State -Name 'omniroute_request_duration_ms_count'
                Write-OmniRouteLog -Level INFO -Message 'request' -Data (ConvertTo-OmniRouteAttemptLog -RequestId $RequestId -Model $route.model -Attempt $attempt -Provider $provider -Status 200 -LatencyMs $result.latencyMs -FallbackReason $null) -Format $Config.logging.format
                return [pscustomobject]@{
                    success     = $true
                    statusCode  = 200
                    body        = ($clientResponse | ConvertTo-Json -Depth 50 -Compress)
                    contentType = 'application/json; charset=utf-8'
                    requestId   = $RequestId
                    provider    = $provider.id
                    model       = $route.model
                    latencyMs   = $result.latencyMs
                    attempts    = $attempt
                    stream      = $false
                    response    = $clientResponse
                }
            }
            catch {
                $lastError = ConvertTo-OmniRouteUpstreamError -Message "Malformed upstream response: $($_.Exception.Message)" -Code 'malformed_upstream_response' -Retryable $true -Exception $_.Exception
                $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $result.attempts -Force
            }
        }
        else { $lastError = $result.error }
        if ($null -ne $lastError) { $lastError | Add-Member -NotePropertyName model -NotePropertyValue $route.model -Force }
        $lastErrorClass = Get-OmniRouteErrorClass -Error $lastError
        $shouldFallback = Test-OmniRouteFallback -Config $Config -Failure $lastError
        Set-OmniProviderFailure -State $State -Provider $provider -Config $Config -Failure $lastError
        Add-OmniRouteMetric -State $State -Name 'omniroute_provider_failures_total' -Labels @{ provider = $provider.id }
        if ($shouldFallback) { Add-OmniRouteMetric -State $State -Name 'omniroute_fallback_total' }
        $fallbackReason = if ($shouldFallback) { $lastErrorClass } else { 'non_fallbackable' }
        $attemptLogs.Add([ordered]@{ attempt = $attempt; provider = $provider.id; status = [int]$lastError.status; latencyMs = $result.latencyMs; fallbackReason = $fallbackReason; code = [string]$lastError.code })
        Write-OmniRouteLog -Level WARN -Message 'provider_failed' -Data (ConvertTo-OmniRouteAttemptLog -RequestId $RequestId -Model $route.model -Attempt $attempt -Provider $provider -Status ([int]$lastError.status) -LatencyMs $result.latencyMs -FallbackReason $fallbackReason) -Format $Config.logging.format
        if (-not $shouldFallback) { break }
    }

    if ($null -eq $lastError) { $lastError = ConvertTo-OmniRouteUpstreamError -Message 'No provider responded.' -Code 'provider_failure' }
    $errorClass = Get-OmniRouteErrorClass -Error $lastError
    $status = if ($errorClass -eq 'timeout') { 504 } elseif ($errorClass -eq 'rate_limit') { 429 } elseif ([int]$lastError.status -gt 0) { [int]$lastError.status } else { 502 }
    return New-OmniRouteErrorResult -Status $status -Type ([string]$lastError.type) -Code ([string]$lastError.code) -Message "All providers failed for model '$($route.originalModel)'. Last error: $($lastError.message)" -RequestId $RequestId -Attempts @($attemptLogs) -Provider $candidates[-1].provider.id -Model $route.model -LatencyMs $canonicalRequestWatch.ElapsedMilliseconds
}

function Start-OmniRouteStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Request,
        [Parameter(Mandatory)][ValidateSet('openai-chat', 'openai-responses', 'anthropic-messages')][string]$InboundProtocol,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [string]$RequestId = (New-OmniRouteRequestId)
    )
    $route = Resolve-OmniRouteModel -Config $Config -Model ([string]$Request.model)
    $canonicalRequest = @{}
    foreach ($key in $Request.Keys) { $canonicalRequest[$key] = $Request[$key] }
    $canonicalRequest.model = $route.model
    $requirement = Get-OmniRouteCapabilityRequirement -Request $canonicalRequest
    if ([string]::IsNullOrWhiteSpace($route.model)) {
        return [pscustomobject]@{ success = $false; errorResult = (New-OmniRouteErrorResult -Status 400 -Type 'routing_error' -Code 'missing_model' -Message "Request field 'model' is required." -RequestId $RequestId) }
    }
    $candidates = Get-OmniRouteCandidates -Config $Config -State $State -Route $route -Requirement $requirement
    if (@($candidates).Count -eq 0) {
        return [pscustomobject]@{ success = $false; errorResult = (New-OmniRouteErrorResult -Status 503 -Type 'routing_error' -Code 'no_provider' -Message "No capable provider available for model '$($route.originalModel)'." -RequestId $RequestId -Model $route.model) }
    }

    $attemptLogs = [System.Collections.Generic.List[object]]::new()
    $lastError = $null
    $attempt = 0
    foreach ($candidate in $candidates) {
        $attempt++
        $provider = $candidate.provider
        Add-OmniRouteMetric -State $State -Name 'omniroute_provider_requests_total' -Labels @{ provider = $provider.id }
        $providerRequestBody = ConvertFrom-OmniRouteCanonicalRequest -Request $canonicalRequest -Provider $provider
        $endpointUri = Get-OmniRouteProviderEndpoint -Provider $provider -Model $route.model -Stream $true
        $headers = Get-OmniRouteProviderHeaders -Provider $provider
        try { $streamResult = Start-OmniRouteUpstreamStream -Provider $provider -Method 'POST' -Uri $endpointUri -Headers $headers -Body $providerRequestBody -Retry $Config.retry -CancellationToken $CancellationToken }
        catch { $streamResult = [pscustomobject]@{ success = $false; error = (ConvertTo-OmniRouteUpstreamError -Message $_.Exception.Message -Code 'upstream_transport_error' -Exception $_.Exception); latencyMs = 0; attempts = 1 } }

        if ($streamResult.success) {
            Add-OmniRouteMetric -State $State -Name 'omniroute_streams_active'
            Write-OmniRouteLog -Level INFO -Message 'stream_open' -Data @{ req = $RequestId; model = $route.model; attempt = $attempt; provider = $provider.id; status = 200; latencyMs = $streamResult.latencyMs } -Format $Config.logging.format
            return [pscustomobject]@{ success = $true; provider = $provider; providerId = $provider.id; model = $route.model; originalModel = $route.originalModel; requestId = $RequestId; endpoint = $InboundProtocol; response = $streamResult.response; request = $streamResult.request; reader = $streamResult.reader; cancellationSource = $streamResult.cancellationSource; latencyMs = $streamResult.latencyMs; attempts = $attempt; error = $null; state = $State; config = $Config; logFormat = $Config.logging.format; cancellationToken = $CancellationToken; cancelled = $false }
        }
        $lastError = $streamResult.error
        if ($null -ne $lastError) { $lastError | Add-Member -NotePropertyName model -NotePropertyValue $route.model -Force }
        $lastErrorClass = Get-OmniRouteErrorClass -Error $lastError
        $shouldFallback = Test-OmniRouteFallback -Config $Config -Failure $lastError
        Set-OmniProviderFailure -State $State -Provider $provider -Config $Config -Failure $lastError
        Add-OmniRouteMetric -State $State -Name 'omniroute_provider_failures_total' -Labels @{ provider = $provider.id }
        if ($shouldFallback) { Add-OmniRouteMetric -State $State -Name 'omniroute_fallback_total' }
        $attemptLogs.Add([ordered]@{ attempt = $attempt; provider = $provider.id; status = [int]$lastError.status; latencyMs = $streamResult.latencyMs; fallbackReason = $lastErrorClass; code = [string]$lastError.code })
        Write-OmniRouteLog -Level WARN -Message 'stream_provider_failed' -Data (ConvertTo-OmniRouteAttemptLog -RequestId $RequestId -Model $route.model -Attempt $attempt -Provider $provider -Status ([int]$lastError.status) -LatencyMs $streamResult.latencyMs -FallbackReason $lastErrorClass) -Format $Config.logging.format
        if (-not $shouldFallback) { break }
    }

    if ($null -eq $lastError) { $lastError = ConvertTo-OmniRouteUpstreamError -Message 'No stream provider responded.' -Code 'provider_failure' }
    $errorClass = Get-OmniRouteErrorClass -Error $lastError
    $status = if ($errorClass -eq 'timeout') { 504 } elseif ($errorClass -eq 'rate_limit') { 429 } elseif ([int]$lastError.status -gt 0) { [int]$lastError.status } else { 502 }
    return [pscustomobject]@{ success = $false; errorResult = (New-OmniRouteErrorResult -Status $status -Type ([string]$lastError.type) -Code ([string]$lastError.code) -Message "All providers failed for model '$($route.originalModel)'. Last error: $($lastError.message)" -RequestId $RequestId -Attempts @($attemptLogs) -Model $route.model) }
}

function Invoke-OmniRouteStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][scriptblock]$Writer
    )
    $streamState = @{
        Id         = 'msg_' + [guid]::NewGuid().ToString('N')
        Model      = $Session.model
        Text       = [System.Text.StringBuilder]::new()
        ToolCallId = ''
        SawDone    = $false
    }
    $eventName = ''
    $dataLines = [System.Collections.Generic.List[string]]::new()
    $errorOccurred = $null
    try {
        if ($Session.endpoint -eq 'anthropic-messages') {
            $startLines = ConvertFrom-OmniRouteCanonicalStreamEvent -StreamEvent @{ type = 'message_start'; id = $streamState.Id; model = $Session.model; usage = @{} } -Protocol $Session.endpoint -State $streamState
            if (@($startLines).Count -gt 0) { & $Writer ($startLines -join "`n") }
        }
        while ($true) {
            $line = $Session.reader.ReadLineAsync($Session.cancellationSource.Token).GetAwaiter().GetResult()
            if ($null -eq $line) { break }
            if ($line.Length -eq 0) {
                if ($dataLines.Count -gt 0) {
                    $data = $dataLines -join "`n"
                    $canonicalEvents = ConvertFrom-OmniRouteProviderStreamEventToCanonical -Provider $Session.provider -Data $data -EventName $eventName -State $streamState
                    foreach ($canonicalEvent in @($canonicalEvents)) {
                        if ($canonicalEvent.type -eq 'content_delta') { [void]$streamState.Text.Append([string]$canonicalEvent.text) }
                        if ($canonicalEvent.type -eq 'done') { $streamState.SawDone = $true }
                        $outputLines = ConvertFrom-OmniRouteCanonicalStreamEvent -StreamEvent $canonicalEvent -Protocol $Session.endpoint -State $streamState
                        if (@($outputLines).Count -gt 0) { & $Writer ($outputLines -join "`n") }
                    }
                    $dataLines.Clear()
                    $eventName = ''
                    if ($streamState.SawDone) { break }
                }
                continue
            }
            if ($line.StartsWith(':')) { continue }
            if ($line.StartsWith('event:')) { $eventName = $line.Substring(6).Trim(); continue }
            if ($line.StartsWith('data:')) { $dataLines.Add($line.Substring(5).TrimStart()) }
        }
        if ($dataLines.Count -gt 0) {
            $canonicalEvents = ConvertFrom-OmniRouteProviderStreamEventToCanonical -Provider $Session.provider -Data ($dataLines -join "`n") -EventName $eventName -State $streamState
            foreach ($canonicalEvent in @($canonicalEvents)) {
                if ($canonicalEvent.type -eq 'content_delta') { [void]$streamState.Text.Append([string]$canonicalEvent.text) }
                if ($canonicalEvent.type -eq 'done') { $streamState.SawDone = $true }
                $outputLines = ConvertFrom-OmniRouteCanonicalStreamEvent -StreamEvent $canonicalEvent -Protocol $Session.endpoint -State $streamState
                if (@($outputLines).Count -gt 0) { & $Writer ($outputLines -join "`n") }
            }
        }
        if (-not $streamState.SawDone) {
            $doneOutput = ConvertFrom-OmniRouteCanonicalStreamEvent -StreamEvent @{ type = 'done'; id = $streamState.Id; model = $Session.model } -Protocol $Session.endpoint -State $streamState
            if (@($doneOutput).Count -gt 0) { & $Writer ($doneOutput -join "`n") }
        }
        Set-OmniProviderSuccess -State $Session.state -Provider $Session.provider -LatencyMs $Session.latencyMs
        Write-OmniRouteLog -Level INFO -Message 'stream_complete' -Data @{ req = $Session.requestId; model = $Session.model; provider = $Session.providerId; status = 200; latencyMs = $Session.latencyMs; attempts = $Session.attempts } -Format $Session.logFormat
    }
    catch [System.OperationCanceledException] {
        if ($Session.cancellationToken.IsCancellationRequested) { throw }
        $errorOccurred = ConvertTo-OmniRouteUpstreamError -Message 'Streaming was interrupted.' -Code 'upstream_stream_error' -Exception $_.Exception
    }
    catch {
        if ($_.Exception -is [System.IO.IOException] -or $_.Exception -is [System.Net.Http.HttpRequestException]) {
            $Session.cancellationSource.Cancel()
            $Session.cancelled = $true
        }
        $errorOccurred = ConvertTo-OmniRouteUpstreamError -Message "Streaming failed: $($_.Exception.Message)" -Code 'upstream_stream_error' -Exception $_.Exception
    }
    finally {
        Add-OmniRouteMetric -State $Session.state -Name 'omniroute_streams_active' -Value -1
        try { $Session.reader.Dispose() } catch { }
        try { $Session.response.Dispose() } catch { }
        try { $Session.request.Dispose() } catch { }
        try { $Session.cancellationSource.Dispose() } catch { }
    }

    if ($null -ne $errorOccurred) {
        Set-OmniProviderFailure -State $Session.state -Provider $Session.provider -Config $Session.config -Failure $errorOccurred
        Add-OmniRouteMetric -State $Session.state -Name 'omniroute_provider_failures_total' -Labels @{ provider = $Session.providerId }
        try {
            $errorEvent = @{ type = 'error'; id = $streamState.Id; model = $Session.model; error = @{ message = $errorOccurred.message; type = $errorOccurred.type; code = $errorOccurred.code } }
            $outputLines = ConvertFrom-OmniRouteCanonicalStreamEvent -StreamEvent $errorEvent -Protocol $Session.endpoint -State $streamState
            if (@($outputLines).Count -gt 0) { & $Writer ($outputLines -join "`n") }
        }
        catch { $Session.cancelled = $true }
        Write-OmniRouteLog -Level ERROR -Message 'stream_failed' -Data @{ req = $Session.requestId; model = $Session.model; provider = $Session.providerId; status = 0; fallbackReason = (Get-OmniRouteErrorClass -Error $errorOccurred) } -Format $Session.logFormat
    }
}
