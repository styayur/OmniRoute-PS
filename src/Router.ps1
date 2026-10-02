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
        [int]$LatencyMs = 0
    )
    $errorObject = [ordered]@{
        message = ConvertTo-OmniRouteRedactedText -Text $Message
        type    = $Type
        code    = $Code
    }
    if ($null -ne $Attempts) { $errorObject.attempts = $Attempts }
    $json = @{ error = $errorObject } | ConvertTo-Json -Depth 20 -Compress
    return [pscustomobject]@{
        success    = $false
        statusCode = $Status
        body       = $json
        contentType = 'application/json; charset=utf-8'
        requestId  = $RequestId
        provider   = $Provider
        model      = $Model
        latencyMs  = $LatencyMs
        attempts   = $Attempts
        stream     = $false
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
    if ($null -ne $forcedProvider) {
        $resolved = $resolved.Substring($forcedProvider.Length + 1)
    }

    $routePattern = $null
    $routeProviders = @()
    $bestScore = -1
    foreach ($pattern in @($Config.routes.Keys)) {
        $wildcard = [System.Management.Automation.WildcardPattern]::new([string]$pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        if (-not $wildcard.IsMatch($resolved)) { continue }
        $patternText = [string]$pattern
        $score = 1000 + ($patternText -replace '[*?\[\]]', '').Length
        if ($patternText -notmatch '[*?\[\]]') { $score += 10000 }
        elseif ($patternText.EndsWith('*') -and @($patternText.ToCharArray() | Where-Object { $_ -eq '*' }).Count -eq 1) { $score += 5000 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $routePattern = $patternText
            $routeProviders = @($Config.routes[$pattern])
        }
    }

    return [pscustomobject]@{
        originalModel   = $Model
        model           = $resolved
        forcedProvider  = $forcedProvider
        routePattern    = $routePattern
        routeProviders  = $routeProviders
    }
}

function Test-OmniRouteProviderUsable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider
    )
    if (-not $Provider.enabled) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$Provider.apiKeyEnv) -and [string]::IsNullOrEmpty((Get-OmniRouteApiKey -Provider $Provider))) { return $false }
    $circuit = Get-OmniCircuitState -State $State -Provider $Provider -Config $Config
    if ($circuit -eq 'Open') { return $false }

    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    if ($runtime.healthy -eq $false -and $null -ne $runtime.lastCheckedAt) {
        $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$runtime.lastCheckedAt).TotalSeconds
        if ($age -le [int]$Config.healthCacheSeconds) { return $false }
    }
    return $true
}

function Get-OmniRouteProviderScore {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Provider
    )
    $runtime = Get-OmniProviderRuntimeState -State $State -ProviderId $Provider.id
    $failurePenalty = [int]$runtime.consecutiveFailures * 20
    $latencyPenalty = if ($null -eq $runtime.movingAverageMs) { 0 } else { [double]$runtime.movingAverageMs / 100.0 }
    $healthPenalty = Get-OmniRouteHealthPenalty -State $State -Provider $Provider
    return [double]$Provider.priority - $failurePenalty - $latencyPenalty - $healthPenalty
}

function Get-OmniRouteCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][object]$Route
    )

    $providerIds = if ($null -ne $Route.forcedProvider) { @([string]$Route.forcedProvider) } else { @($Route.routeProviders) }
    $candidates = [System.Collections.Generic.List[object]]::new()
    $order = 0
    foreach ($providerId in $providerIds) {
        $provider = Get-OmniRouteProvider -Config $Config -Id $providerId
        if ($null -eq $provider) { continue }
        if (-not (Test-OmniRouteProviderUsable -Config $Config -State $State -Provider $provider)) { continue }
        $candidates.Add([pscustomobject]@{
            provider = $provider
            score    = Get-OmniRouteProviderScore -State $State -Provider $provider
            order    = $order
        })
        $order++
    }
    return @($candidates | Sort-Object -Property @{ Expression = { [double]$_.score }; Descending = $true }, @{ Expression = { [int]$_.order }; Descending = $false })
}

function Test-OmniRouteFallback {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Alias('Error')]
        [AllowNull()][object]$Failure
    )
    if ($null -eq $Failure) { return $false }
    $code = [string]$Failure.code
    if ($code -in @('upstream_timeout', 'upstream_connection_failed', 'malformed_upstream_response')) { return $true }
    $status = [int]$Failure.status
    return $status -in @($Config.fallbackOnStatus)
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
    return @{
        req            = $RequestId
        model          = $Model
        attempt        = $Attempt
        provider       = $Provider.id
        status         = $Status
        latencyMs      = $LatencyMs
        fallbackReason = $FallbackReason
    }
}

function Invoke-OmniRouteRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$RequestBody,
        [ValidateSet('chat', 'responses')][string]$Endpoint = 'chat',
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [string]$RequestId = (New-OmniRouteRequestId)
    )

    $route = Resolve-OmniRouteModel -Config $Config -Model ([string]$RequestBody.model)
    if ([string]::IsNullOrWhiteSpace($route.model)) {
        return New-OmniRouteErrorResult -Status 400 -Type 'routing_error' -Code 'missing_model' -Message "Request field 'model' is required." -RequestId $RequestId -Model $route.model
    }
    $candidates = Get-OmniRouteCandidates -Config $Config -State $State -Route $route
    if ($candidates.Count -eq 0) {
        $message = "No healthy provider available for model '$($route.originalModel)'."
        Write-OmniRouteLog -Level WARN -Message 'routing_failed' -Data @{ req = $RequestId; model = $route.model; route = $route.routePattern } -Format $Config.logging.format
        return New-OmniRouteErrorResult -Status 503 -Type 'routing_error' -Code 'no_provider' -Message $message -RequestId $RequestId -Model $route.model
    }

    $attemptLogs = [System.Collections.Generic.List[object]]::new()
    $lastError = $null
    $attempt = 0
    foreach ($candidate in $candidates) {
        $attempt++
        $provider = $candidate.provider
        $providerRequestBody = ConvertTo-OmniRouteProviderRequest -Provider $provider -RequestBody $RequestBody -Model $route.model -Stream $false
        $endpointUri = Get-OmniRouteProviderEndpoint -Provider $provider -Model $route.model -Stream $false
        $headers = Get-OmniRouteProviderHeaders -Provider $provider
        $result = Invoke-OmniRouteUpstreamRequest -Provider $provider -Method 'POST' -Uri $endpointUri -Headers $headers -Body $providerRequestBody -Retry $Config.retry -CancellationToken $CancellationToken
        if ($result.success) {
            try {
                $providerResponse = ConvertFrom-OmniRouteProviderResponse -Provider $provider -Content $result.content -Model $route.model
                if (Get-OmniRouteDictValue -Dictionary $providerResponse -Name 'error' -Default $null) {
                    throw "Upstream returned an error object with HTTP 200: $([string](Get-OmniRouteDictValue -Dictionary $providerResponse -Name 'message' -Default 'unknown error'))"
                }
                $clientResponse = if ($Endpoint -eq 'responses') { ConvertFrom-OmniRouteChatToResponses -ChatResponse $providerResponse -Model $route.model } else { $providerResponse }
                Set-OmniProviderSuccess -State $State -Provider $provider -LatencyMs $result.latencyMs
                $logData = ConvertTo-OmniRouteAttemptLog -RequestId $RequestId -Model $route.model -Attempt $attempt -Provider $provider -Status 200 -LatencyMs $result.latencyMs -FallbackReason $null
                Write-OmniRouteLog -Level INFO -Message 'request' -Data $logData -Format $Config.logging.format
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
        else {
            $lastError = $result.error
        }

        $shouldFallback = Test-OmniRouteFallback -Config $Config -Error $lastError
        if ($shouldFallback) {
            Set-OmniProviderFailure -State $State -Provider $provider -Config $Config -Error $lastError
        }
        $fallbackReason = if ($shouldFallback) { [string]$lastError.code } else { 'non_fallbackable' }
        $logData = ConvertTo-OmniRouteAttemptLog -RequestId $RequestId -Model $route.model -Attempt $attempt -Provider $provider -Status ([int]$lastError.status) -LatencyMs $result.latencyMs -FallbackReason $fallbackReason
        Write-OmniRouteLog -Level WARN -Message 'provider_failed' -Data $logData -Format $Config.logging.format
        $attemptLogs.Add([ordered]@{
            attempt        = $attempt
            provider       = $provider.id
            status         = [int]$lastError.status
            latencyMs      = $result.latencyMs
            fallbackReason = $fallbackReason
            code           = [string]$lastError.code
        })

        if (-not $shouldFallback) { break }
    }

    if ($null -eq $lastError) {
        return New-OmniRouteErrorResult -Status 502 -Type 'provider_error' -Code 'provider_failure' -Message "All providers failed for model '$($route.originalModel)'." -RequestId $RequestId -Model $route.model -Attempts @($attemptLogs)
    }
    $status = if ([string]$lastError.type -eq 'timeout_error') { 504 } elseif ([int]$lastError.status -gt 0) { [int]$lastError.status } else { 502 }
    if ($status -lt 400 -or $status -gt 599) { $status = 502 }
    return New-OmniRouteErrorResult -Status $status -Type ([string]$lastError.type) -Code ([string]$lastError.code) -Message "All providers failed for model '$($route.originalModel)'. Last error: $($lastError.message)" -RequestId $RequestId -Attempts @($attemptLogs) -Provider $candidates[-1].provider.id -Model $route.model -LatencyMs $result.latencyMs
}

function Start-OmniRouteStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$RequestBody,
        [ValidateSet('chat', 'responses')][string]$Endpoint = 'chat',
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [string]$RequestId = (New-OmniRouteRequestId)
    )

    $route = Resolve-OmniRouteModel -Config $Config -Model ([string]$RequestBody.model)
    if ([string]::IsNullOrWhiteSpace($route.model)) {
        return [pscustomobject]@{ success = $false; errorResult = (New-OmniRouteErrorResult -Status 400 -Type 'routing_error' -Code 'missing_model' -Message "Request field 'model' is required." -RequestId $RequestId) }
    }
    $candidates = Get-OmniRouteCandidates -Config $Config -State $State -Route $route
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ success = $false; errorResult = (New-OmniRouteErrorResult -Status 503 -Type 'routing_error' -Code 'no_provider' -Message "No healthy provider available for model '$($route.originalModel)'." -RequestId $RequestId -Model $route.model) }
    }

    $attemptLogs = [System.Collections.Generic.List[object]]::new()
    $lastError = $null
    $attempt = 0
    foreach ($candidate in $candidates) {
        $attempt++
        $provider = $candidate.provider
        $providerRequestBody = ConvertTo-OmniRouteProviderRequest -Provider $provider -RequestBody $RequestBody -Model $route.model -Stream $true
        $endpointUri = Get-OmniRouteProviderEndpoint -Provider $provider -Model $route.model -Stream $true
        $headers = Get-OmniRouteProviderHeaders -Provider $provider
        try {
            $streamResult = Open-OmniRouteUpstreamStream -Provider $provider -Method 'POST' -Uri $endpointUri -Headers $headers -Body $providerRequestBody -Retry $Config.retry -CancellationToken $CancellationToken
        }
        catch {
            $streamResult = [pscustomobject]@{ success = $false; error = (ConvertTo-OmniRouteUpstreamError -Message $_.Exception.Message -Code 'upstream_transport_error' -Exception $_.Exception); latencyMs = 0; attempts = 1 }
        }

        if ($streamResult.success) {
            Write-OmniRouteLog -Level INFO -Message 'stream_open' -Data @{ req = $RequestId; model = $route.model; attempt = $attempt; provider = $provider.id; status = 200; latencyMs = $streamResult.latencyMs } -Format $Config.logging.format
            return [pscustomobject]@{
                success            = $true
                provider           = $provider
                providerId         = $provider.id
                model              = $route.model
                originalModel      = $route.originalModel
                requestId          = $RequestId
                endpoint           = $Endpoint
                response           = $streamResult.response
                request            = $streamResult.request
                reader             = $streamResult.reader
                cancellationSource = $streamResult.cancellationSource
                latencyMs          = $streamResult.latencyMs
                attempts           = $attempt
                error              = $null
                state              = $State
                config             = $Config
                logFormat          = $Config.logging.format
                cancellationToken  = $CancellationToken
                cancelled          = $false
            }
        }

        $lastError = $streamResult.error
        $shouldFallback = Test-OmniRouteFallback -Config $Config -Error $lastError
        if ($shouldFallback) {
            Set-OmniProviderFailure -State $State -Provider $provider -Config $Config -Error $lastError
        }
        $fallbackReason = if ($shouldFallback) { [string]$lastError.code } else { 'non_fallbackable' }
        $attemptLogs.Add([ordered]@{
            attempt        = $attempt
            provider       = $provider.id
            status         = [int]$lastError.status
            latencyMs      = $streamResult.latencyMs
            fallbackReason = $fallbackReason
            code           = [string]$lastError.code
        })
        Write-OmniRouteLog -Level WARN -Message 'stream_provider_failed' -Data (ConvertTo-OmniRouteAttemptLog -RequestId $RequestId -Model $route.model -Attempt $attempt -Provider $provider -Status ([int]$lastError.status) -LatencyMs $streamResult.latencyMs -FallbackReason $fallbackReason) -Format $Config.logging.format
        if (-not $shouldFallback) { break }
    }

    if ($null -eq $lastError) {
        $lastError = ConvertTo-OmniRouteUpstreamError -Message 'No stream provider responded.' -Code 'provider_failure'
    }
    $status = if ([string]$lastError.type -eq 'timeout_error') { 504 } elseif ([int]$lastError.status -gt 0) { [int]$lastError.status } else { 502 }
    $errorResult = New-OmniRouteErrorResult -Status $status -Type ([string]$lastError.type) -Code ([string]$lastError.code) -Message "All providers failed for model '$($route.originalModel)'. Last error: $($lastError.message)" -RequestId $RequestId -Attempts @($attemptLogs) -Model $route.model
    return [pscustomobject]@{ success = $false; errorResult = $errorResult }
}

function Invoke-OmniRouteStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][scriptblock]$Writer
    )

    $state = @{
        Id       = 'chatcmpl-' + [guid]::NewGuid().ToString('N')
        Model    = $Session.model
        Text     = [System.Text.StringBuilder]::new()
        SawDone  = $false
    }
    $eventName = ''
    $dataLines = [System.Collections.Generic.List[string]]::new()
    $errorOccurred = $null

    try {
        while ($true) {
            $line = $Session.reader.ReadLineAsync($Session.cancellationSource.Token).GetAwaiter().GetResult()
            if ($null -eq $line) { break }
            if ($line.Length -eq 0) {
                if ($dataLines.Count -gt 0) {
                    $data = $dataLines -join "`n"
                    $outputLines = ConvertFrom-OmniRouteProviderStreamEvent -Provider $Session.provider -Data $data -EventName $eventName -Endpoint $Session.endpoint -State $state
                    if (@($outputLines).Count -gt 0) { & $Writer ($outputLines -join "`n") }
                    if ($outputLines -match '^data: \[DONE\]$' -or $outputLines -match 'response.completed') { $state.SawDone = $true }
                    $dataLines.Clear()
                    if ($state.SawDone) { break }
                    $eventName = ''
                }
                continue
            }
            if ($line.StartsWith(':')) { continue }
            if ($line.StartsWith('event:')) { $eventName = $line.Substring(6).Trim(); continue }
            if ($line.StartsWith('data:')) { $dataLines.Add($line.Substring(5).TrimStart()) }
        }
        if ($dataLines.Count -gt 0) {
            $data = $dataLines -join "`n"
            $outputLines = ConvertFrom-OmniRouteProviderStreamEvent -Provider $Session.provider -Data $data -EventName $eventName -Endpoint $Session.endpoint -State $state
            if (@($outputLines).Count -gt 0) { & $Writer ($outputLines -join "`n") }
            if ($outputLines -match '^data: \[DONE\]$' -or $outputLines -match 'response.completed') { $state.SawDone = $true }
        }
        if (-not $state.SawDone) {
            if ($Session.endpoint -eq 'responses') {
                & $Writer ('event: response.completed' + "`n" + 'data: ' + (@{ type = 'response.completed'; response = (@{ id = $state.Id; object = 'response'; status = 'completed'; model = $state.Model; output_text = $state.Text.ToString() }) } | ConvertTo-Json -Depth 20 -Compress))
            }
            else {
                & $Writer 'data: [DONE]'
            }
        }
        Set-OmniProviderSuccess -State $Session.state -Provider $Session.provider -LatencyMs $Session.latencyMs
        Write-OmniRouteLog -Level INFO -Message 'stream_complete' -Data @{ req = $Session.requestId; model = $Session.model; provider = $Session.providerId; status = 200; latencyMs = $Session.latencyMs; attempts = $Session.attempts } -Format $Session.logFormat
    }
    catch [System.OperationCanceledException] {
        if ($Session.cancellationToken.IsCancellationRequested) { throw }
        $errorOccurred = ConvertTo-OmniRouteUpstreamError -Message 'Streaming was interrupted.' -Code 'upstream_stream_error' -Exception $_.Exception
    }
    catch {
        if (-not $state.SawDone) {
            if ($_.Exception -is [System.IO.IOException] -or $_.Exception -is [System.Net.Http.HttpRequestException]) {
                $Session.cancellationSource.Cancel()
            }
            $errorOccurred = ConvertTo-OmniRouteUpstreamError -Message "Streaming failed: $($_.Exception.Message)" -Code 'upstream_stream_error' -Exception $_.Exception
        }
    }
    finally {
        try { $Session.reader.Dispose() } catch { }
        try { $Session.response.Dispose() } catch { }
        try { $Session.request.Dispose() } catch { }
        try { $Session.cancellationSource.Dispose() } catch { }
    }

    if ($null -ne $errorOccurred) {
        Set-OmniProviderFailure -State $Session.state -Provider $Session.provider -Config $Session.config -Error $errorOccurred
        try {
            if ($Session.endpoint -eq 'responses') {
                & $Writer ('event: response.failed' + "`n" + 'data: ' + (@{ type = 'response.failed'; error = @{ message = $errorOccurred.message; type = $errorOccurred.type; code = $errorOccurred.code } } | ConvertTo-Json -Depth 20 -Compress))
            }
            else {
                & $Writer ('event: error' + "`n" + 'data: ' + (@{ error = @{ message = $errorOccurred.message; type = $errorOccurred.type; code = $errorOccurred.code } } | ConvertTo-Json -Depth 20 -Compress) + "`n" + 'data: [DONE]')
            }
        }
        catch {
            $Session.cancelled = $true
        }
        Write-OmniRouteLog -Level ERROR -Message 'stream_failed' -Data @{ req = $Session.requestId; model = $Session.model; provider = $Session.providerId; status = 0; fallbackReason = $errorOccurred.code } -Format $Session.logFormat
    }
}
