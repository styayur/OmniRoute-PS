Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-OmniRouteCorsHeaders {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][hashtable]$Config
    )
    if (-not [bool]$Config.http.cors.enabled) { return $false }
    $origin = [string]$Context.Request.Headers['Origin']
    if ([string]::IsNullOrWhiteSpace($origin)) { return $false }
    if ($origin -notin @($Config.http.cors.allowedOrigins)) { return $false }
    $Context.Response.Headers['Access-Control-Allow-Origin'] = $origin
    $Context.Response.Headers['Vary'] = 'Origin'
    $Context.Response.Headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type, anthropic-version, x-api-key'
    $Context.Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    return $true
}

function Write-OmniRouteHttpResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$Body,
        [hashtable]$Config,
        [string]$ContentType = 'application/json; charset=utf-8',
        [string]$RequestId = '',
        [int]$RetryAfterSeconds = 0
    )
    if ($PSBoundParameters.ContainsKey('Config')) { [void](Set-OmniRouteCorsHeaders -Context $Context -Config $Config) }
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.Headers['Cache-Control'] = 'no-store'
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) { $response.Headers['X-Request-Id'] = $RequestId }
    if ($RetryAfterSeconds -gt 0) { $response.Headers['Retry-After'] = [string]$RetryAfterSeconds }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Flush()
    $response.Close()
}

function Read-OmniRouteRequestBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context, [Parameter(Mandatory)][int]$MaxBytes)
    if ($Context.Request.ContentLength64 -gt $MaxBytes) { throw [System.IO.InvalidDataException]::new("Request body exceeds the configured limit of $MaxBytes bytes.") }
    $memory = [System.IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(16384)
        $total = 0
        while (($read = $Context.Request.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) { throw [System.IO.InvalidDataException]::new("Request body exceeds the configured limit of $MaxBytes bytes.") }
            $memory.Write($buffer, 0, $read)
        }
        return [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
    }
    finally { $memory.Dispose() }
}

function ConvertFrom-OmniRouteRequestBody {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw "Invalid request: JSON body is required." }
    try { $body = $Json | ConvertFrom-Json -AsHashtable } catch { throw "Invalid request JSON: $($_.Exception.Message)" }
    if ($body -isnot [System.Collections.IDictionary]) { throw 'Invalid request: JSON body must be an object.' }
    return $body
}

function Get-OmniRouteModelsResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $models = [System.Collections.Generic.List[object]]::new()
    foreach ($providerId in @($Config.providers.Keys)) {
        foreach ($model in @($Config.providers[$providerId].models)) {
            if ($seen.Add([string]$model)) { $models.Add([ordered]@{ id = [string]$model; object = 'model'; created = 0; owned_by = $providerId }) }
        }
    }
    foreach ($alias in @($Config.aliases.Keys)) {
        if ($seen.Add([string]$alias)) { $models.Add([ordered]@{ id = [string]$alias; object = 'model'; created = 0; owned_by = 'alias' }) }
    }
    return [ordered]@{ object = 'list'; data = @($models) }
}

function Get-OmniRouteWorkerSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$State)
    return @{ active = [int]$State.workers.active; available = [int]$State.workers.available; queued = [int]$State.workers.queued }
}

function Invoke-OmniRouteHttpContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [bool]$DebugMode = $false,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )
    $requestId = New-OmniRouteRequestId
    $path = $Context.Request.Url.AbsolutePath
    $method = $Context.Request.HttpMethod.ToUpperInvariant()
    Add-OmniRouteMetric -State $State -Name 'omniroute_requests_total'

    try {
        if ($method -eq 'OPTIONS') {
            $corsAllowed = Set-OmniRouteCorsHeaders -Context $Context -Config $Config
            if ($Config.http.cors.enabled -and -not $corsAllowed) {
                $result = New-OmniRouteErrorResult -Status 403 -Type 'routing_error' -Code 'cors_origin_denied' -Message 'CORS origin is not allowed.' -RequestId $requestId
                Write-OmniRouteHttpResponse -Context $Context -StatusCode 403 -Body $result.body -Config $Config -RequestId $requestId
                return
            }
            $Context.Response.StatusCode = 204
            $Context.Response.Close()
            return
        }

        if ($method -eq 'GET' -and $path -eq '/health/live') {
            $body = [ordered]@{ status = 'ok'; version = Get-OmniRouteVersion; uptimeSec = [int]([DateTimeOffset]::UtcNow - $State.startedAt).TotalSeconds } | ConvertTo-Json -Compress -Depth 10
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 200 -Body $body -Config $Config -RequestId $requestId
            return
        }

        if ($method -eq 'GET' -and $path -eq '/health/ready') {
            $readiness = Get-OmniRouteReadiness -Config $Config -State $State
            $statusCode = if ($readiness.ready) { 200 } else { 503 }
            $body = [ordered]@{ status = if ($readiness.ready) { 'ready' } else { 'not_ready' }; ready = [bool]$readiness.ready; reasons = @($readiness.reasons); workers = (Get-OmniRouteWorkerSnapshot -State $State); version = Get-OmniRouteVersion } | ConvertTo-Json -Compress -Depth 10
            Write-OmniRouteHttpResponse -Context $Context -StatusCode $statusCode -Body $body -Config $Config -RequestId $requestId
            return
        }

        if ($method -eq 'GET' -and $path -eq '/health') {
            $body = Get-OmniRouteHealthReport -Config $Config -State $State -WorkerSnapshot (Get-OmniRouteWorkerSnapshot -State $State) | ConvertTo-Json -Depth 30 -Compress
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 200 -Body $body -Config $Config -RequestId $requestId
            return
        }

        if ($method -eq 'GET' -and $path -eq '/metrics') {
            $body = Get-OmniRouteMetrics -State $State
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 200 -Body $body -Config $Config -ContentType 'text/plain; version=0.0.4; charset=utf-8' -RequestId $requestId
            return
        }

        if ($method -eq 'GET' -and $path -eq '/v1/models') {
            $body = Get-OmniRouteModelsResponse -Config $Config | ConvertTo-Json -Depth 20 -Compress
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 200 -Body $body -Config $Config -RequestId $requestId
            return
        }

        $postRoutes = @{
            '/v1/chat/completions' = 'openai-chat'
            '/v1/responses'        = 'openai-responses'
            '/v1/messages'         = 'anthropic-messages'
        }
        if ($method -eq 'POST' -and $postRoutes.ContainsKey($path)) {
            $rawBody = Read-OmniRouteRequestBody -Context $Context -MaxBytes ([int]$Config.maxRequestBodyBytes)
            $requestBody = ConvertFrom-OmniRouteRequestBody -Json $rawBody
            $protocol = $postRoutes[$path]
            $canonical = ConvertTo-OmniRouteCanonicalRequest -Body $requestBody -Protocol $protocol
            if ($canonical.stream) {
                $session = Start-OmniRouteStream -Config $Config -State $State -Request $canonical -InboundProtocol $protocol -RequestId $requestId -CancellationToken $CancellationToken
                if (-not $session.success) {
                    Write-OmniRouteHttpResponse -Context $Context -StatusCode $session.errorResult.statusCode -Body $session.errorResult.body -Config $Config -RequestId $requestId
                    return
                }
                $response = $Context.Response
                [void](Set-OmniRouteCorsHeaders -Context $Context -Config $Config)
                $response.StatusCode = 200
                $response.ContentType = 'text/event-stream; charset=utf-8'
                $response.Headers['Cache-Control'] = 'no-cache, no-transform'
                $response.Headers['X-Accel-Buffering'] = 'no'
                $response.Headers['X-Request-Id'] = $requestId
                $response.SendChunked = $true
                $utf8 = [System.Text.UTF8Encoding]::new($false)
                $writer = {
                    param([string]$Block)
                    $payload = $Block + "`n`n"
                    $bytes = $utf8.GetBytes($payload)
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Flush()
                }
                Invoke-OmniRouteStream -Session $session -Writer $writer
                try { $response.Close() } catch { }
                return
            }
            $result = Invoke-OmniRouteRequest -Config $Config -State $State -Request $canonical -InboundProtocol $protocol -RequestId $requestId -CancellationToken $CancellationToken
            Write-OmniRouteHttpResponse -Context $Context -StatusCode $result.statusCode -Body $result.body -Config $Config -RequestId $requestId
            return
        }

        $notFound = New-OmniRouteErrorResult -Status 404 -Type 'routing_error' -Code 'not_found' -Message "No route for $method $path." -RequestId $requestId
        Write-OmniRouteHttpResponse -Context $Context -StatusCode 404 -Body $notFound.body -Config $Config -RequestId $requestId
    }
    catch [System.IO.InvalidDataException] {
        $errorResult = New-OmniRouteErrorResult -Status 413 -Type 'config_error' -Code 'request_too_large' -Message $_.Exception.Message -RequestId $requestId
        Write-OmniRouteHttpResponse -Context $Context -StatusCode 413 -Body $errorResult.body -Config $Config -RequestId $requestId
    }
    catch {
        $message = $_.Exception.Message
        $isClientError = $message -match '^(Invalid request|Unsupported parameter)'
        if ($isClientError) {
            $code = if ($message -match 'Unsupported parameter') { 'unsupported_feature' } else { 'invalid_request' }
            $errorResult = New-OmniRouteErrorResult -Status 400 -Type 'routing_error' -Code $code -Message $message -RequestId $requestId
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 400 -Body $errorResult.body -Config $Config -RequestId $requestId
        }
        else {
            $detail = if ($DebugMode) { $_.Exception.ToString() + [Environment]::NewLine + $_.ScriptStackTrace } else { $message }
            Write-OmniRouteLog -Level ERROR -Message 'internal_error' -Data @{ req = $requestId; detail = $detail } -Format $Config.logging.format
            $errorResult = New-OmniRouteErrorResult -Status 500 -Type 'internal_error' -Code 'internal_error' -Message 'Internal server error.' -RequestId $requestId
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 500 -Body $errorResult.body -Config $Config -RequestId $requestId
        }
    }
}

function Start-OmniRouteServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$ConfigPath = $Config.sourcePath,
        [bool]$DebugMode = $false,
        [AllowNull()][object]$State = $null
    )
    if ($null -eq $State) { $State = New-OmniRouteState }
    if (-not [System.Net.HttpListener]::IsSupported) { throw 'System.Net.HttpListener is not supported on this platform.' }
    $hostName = [string]$Config.listen
    if ($hostName -in @('0.0.0.0', '*')) {
        $prefix = "http://*:$($Config.port)/"
        Write-OmniRouteLog -Level WARN -Message 'network_exposure' -Data @{ listen = $hostName; port = $Config.port; warning = 'OmniRoute-PS is reachable on the local network.' } -Format $Config.logging.format
    }
    elseif ($hostName -eq '::') { $prefix = "http://[$hostName]:$($Config.port)/" }
    else { $prefix = "http://$hostName`:$($Config.port)/" }

    $root = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $root 'src/OmniRoute.psm1'
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    [void]$initialSessionState.ImportPSModule(@($modulePath))
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        [int]$Config.server.minWorkers,
        [int]$Config.server.maxWorkers,
        $initialSessionState,
        $Host
    )
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    $capacity = [System.Threading.SemaphoreSlim]::new(
        [int]$Config.server.maxWorkers + [int]$Config.server.maxQueuedRequests,
        [int]$Config.server.maxWorkers + [int]$Config.server.maxQueuedRequests
    )
    $active = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    $configState = [System.Collections.Hashtable]::Synchronized(@{
        Current       = $Config
        Path          = $ConfigPath
        LastWriteUtc  = $null
        LastReloadAt  = $null
        LastError     = $null
    })
    $configItem = Get-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
    if ($null -ne $configItem) { $configState.LastWriteUtc = $configItem.LastWriteTimeUtc }
    $reloadDue = $null
    $workerScript = @(
        'param($Context, $ConfigState, $State, $DebugMode, $CancellationToken)'
        '$currentConfig = $ConfigState.Current'
        'Invoke-OmniRouteHttpContext -Context $Context -Config $currentConfig -State $State -DebugMode $DebugMode -CancellationToken $CancellationToken'
    ) -join "`n"

    try {
        $pool.Open()
        $listener.Start()
        $State.initialized = $true
        $State.shuttingDown = $false
        Write-OmniRouteLog -Level INFO -Message 'server_start' -Data @{ listen = $hostName; port = $Config.port; config = $ConfigPath; providers = $Config.providers.Count; workers = $Config.server.maxWorkers; queue = $Config.server.maxQueuedRequests } -Format $Config.logging.format
        Write-Host "OmniRoute-PS $(Get-OmniRouteVersion) listening on $prefix" -ForegroundColor Green
        Write-Host "Config: $ConfigPath"
        Write-Host 'Press Ctrl+C to stop.'

        $acceptTask = $listener.GetContextAsync()
        while (-not $State.shuttingDown) {
            $count = $active.Count
            $State.workers.active = [Math]::Min($count, [int]$Config.server.maxWorkers)
            $State.workers.available = [Math]::Max(0, [int]$Config.server.maxWorkers - $count)
            $State.workers.queued = [Math]::Max(0, $count - [int]$Config.server.maxWorkers)
            Set-OmniRouteMetric -State $State -Name 'omniroute_requests_active' -Value $State.workers.active
            Set-OmniRouteMetric -State $State -Name 'omniroute_requests_queued' -Value $State.workers.queued

            foreach ($entry in @($active.ToArray())) {
                if ($entry.AsyncResult.IsCompleted) {
                    try { $null = $entry.Pipeline.EndInvoke($entry.AsyncResult) }
                    catch { Write-OmniRouteLog -Level ERROR -Message 'worker_failure' -Data @{ detail = $_.Exception.Message } -Format $Config.logging.format }
                    $entry.Pipeline.Dispose()
                    $entry.CancellationSource.Dispose()
                    [void]$active.Remove($entry)
                    [void]$capacity.Release()
                }
            }

            $now = [DateTimeOffset]::UtcNow
            $configItem = Get-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
            if ($null -ne $configItem) {
                $writeUtc = $configItem.LastWriteTimeUtc
                if ($null -eq $configState.LastWriteUtc -or $writeUtc -gt [DateTime]$configState.LastWriteUtc) {
                    $configState.LastWriteUtc = $writeUtc
                    $reloadDue = $now.AddMilliseconds(500)
                }
            }
            if ($null -ne $reloadDue -and $now -ge $reloadDue) {
                try {
                    $candidate = Test-OmniRouteConfig -Path $ConfigPath -BasePath $root
                    if ($candidate.valid) {
                        $configState.Current = $candidate.config
                        $configState.LastReloadAt = $now
                        $configState.LastError = $null
                        $State.configRevision++
                        Write-OmniRouteLog -Level INFO -Message 'config_reload_ok' -Data @{ config = $ConfigPath; revision = $State.configRevision } -Format $Config.logging.format
                    }
                    else {
                        $message = @($candidate.errors | ForEach-Object { "$($_.path): $($_.message)" }) -join '; '
                        $configState.LastError = $message
                        Write-OmniRouteLog -Level WARN -Message 'config_reload_rejected' -Data @{ config = $ConfigPath; error = $message } -Format $Config.logging.format
                    }
                }
                catch {
                    $configState.LastError = $_.Exception.Message
                    Write-OmniRouteLog -Level WARN -Message 'config_reload_failed' -Data @{ config = $ConfigPath; error = $_.Exception.Message } -Format $Config.logging.format
                }
                $reloadDue = $null
            }

            if ($acceptTask.Wait(100)) {
                $context = $acceptTask.Result
                $acceptTask = $listener.GetContextAsync()
                if (-not $capacity.Wait(0)) {
                    $result = New-OmniRouteErrorResult -Status 503 -Type 'routing_error' -Code 'worker_pool_saturated' -Message 'Worker pool and queue are saturated.' -RequestId (New-OmniRouteRequestId) -RetryAfter
                    Write-OmniRouteHttpResponse -Context $context -StatusCode 503 -Body $result.body -Config $configState.Current -RequestId $result.requestId -RetryAfterSeconds 1
                    continue
                }
                $cts = [System.Threading.CancellationTokenSource]::new()
                $pipeline = [System.Management.Automation.PowerShell]::Create()
                $pipeline.RunspacePool = $pool
                [void]$pipeline.AddScript($workerScript).AddArgument($context).AddArgument($configState).AddArgument($State).AddArgument($DebugMode).AddArgument($cts.Token)
                $asyncResult = $pipeline.BeginInvoke()
                [void]$active.Add([pscustomobject]@{ Pipeline = $pipeline; AsyncResult = $asyncResult; CancellationSource = $cts })
            }
        }
    }
    finally {
        $State.shuttingDown = $true
        $State.initialized = $false
        try { $listener.Stop() } catch { }
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$Config.server.shutdownGraceSeconds)
        while ($active.Count -gt 0 -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        foreach ($entry in @($active.ToArray())) {
            try { $entry.CancellationSource.Cancel() } catch { }
            try { $entry.Pipeline.Stop() } catch { }
            try { $entry.Pipeline.Dispose() } catch { }
            try { $entry.CancellationSource.Dispose() } catch { }
            [void]$active.Remove($entry)
        }
        try { $pool.Close() } catch { }
        try { $pool.Dispose() } catch { }
        $capacity.Dispose()
        try { $listener.Close() } catch { }
        Write-OmniRouteLog -Level INFO -Message 'server_stop' -Data @{ listen = $hostName; port = $Config.port } -Format $Config.logging.format
    }
}
