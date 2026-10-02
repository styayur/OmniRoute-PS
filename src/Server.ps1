Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-OmniRouteHttpResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$Body,
        [string]$ContentType = 'application/json; charset=utf-8',
        [string]$RequestId = ''
    )

    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.Headers['Cache-Control'] = 'no-store'
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) { $response.Headers['X-Request-Id'] = $RequestId }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Flush()
    $response.Close()
}

function Read-OmniRouteRequestBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][int]$MaxBytes
    )

    if ($Context.Request.ContentLength64 -gt $MaxBytes) {
        throw [System.IO.InvalidDataException]::new("Request body exceeds the configured limit of $MaxBytes bytes.")
    }
    $memory = [System.IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(16384)
        $total = 0
        while (($read = $Context.Request.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) {
                throw [System.IO.InvalidDataException]::new("Request body exceeds the configured limit of $MaxBytes bytes.")
            }
            $memory.Write($buffer, 0, $read)
        }
        return [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
    }
    finally {
        $memory.Dispose()
    }
}

function ConvertFrom-OmniRouteRequestBody {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw "Invalid request: JSON body is required." }
    try { $body = $Json | ConvertFrom-Json -AsHashtable }
    catch { throw "Invalid request JSON: $($_.Exception.Message)" }
    if ($body -isnot [System.Collections.IDictionary]) { throw 'Invalid request: JSON body must be an object.' }
    return $body
}

function Get-OmniRouteModelsResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $models = [System.Collections.Generic.List[object]]::new()
    foreach ($providerId in @($Config.providers.Keys)) {
        $provider = $Config.providers[$providerId]
        foreach ($model in @($provider.models)) {
            if ($seen.Add([string]$model)) {
                $models.Add([ordered]@{
                    id       = [string]$model
                    object   = 'model'
                    created  = 0
                    owned_by = $providerId
                })
            }
        }
    }
    foreach ($alias in @($Config.aliases.Keys)) {
        if ($seen.Add([string]$alias)) {
            $models.Add([ordered]@{ id = [string]$alias; object = 'model'; created = 0; owned_by = 'alias' })
        }
    }
    return [ordered]@{ object = 'list'; data = @($models) }
}

function Invoke-OmniRouteHttpContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [bool]$DebugMode = $false
    )

    $requestId = New-OmniRouteRequestId
    $path = $Context.Request.Url.AbsolutePath
    $method = $Context.Request.HttpMethod.ToUpperInvariant()
    $State.totalRequests++
    $State.activeRequests++
    $State.lastRequestAt = [DateTimeOffset]::UtcNow

    try {
        if ($method -eq 'OPTIONS') {
            $Context.Response.StatusCode = 204
            $Context.Response.Headers['Access-Control-Allow-Origin'] = '*'
            $Context.Response.Headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type'
            $Context.Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
            $Context.Response.Close()
            return
        }

        if ($method -eq 'GET' -and $path -eq '/health') {
            $body = Get-OmniRouteHealthReport -Config $Config -State $State | ConvertTo-Json -Depth 20 -Compress
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 200 -Body $body -RequestId $requestId
            return
        }

        if ($method -eq 'GET' -and $path -eq '/v1/models') {
            $body = Get-OmniRouteModelsResponse -Config $Config | ConvertTo-Json -Depth 20 -Compress
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 200 -Body $body -RequestId $requestId
            return
        }

        if ($method -eq 'POST' -and $path -in @('/v1/chat/completions', '/v1/responses')) {
            $rawBody = Read-OmniRouteRequestBody -Context $Context -MaxBytes ([int]$Config.maxRequestBodyBytes)
            $requestBody = ConvertFrom-OmniRouteRequestBody -Json $rawBody
            $endpoint = if ($path -eq '/v1/responses') { 'responses' } else { 'chat' }
            if ($endpoint -eq 'responses') { $requestBody = ConvertTo-OmniRouteResponsesChatRequest -RequestBody $requestBody }

            if ($null -eq (Get-OmniRouteDictValue -Dictionary $requestBody -Name 'model' -Default $null)) {
                throw "Invalid request: 'model' is required."
            }
            $isStream = [bool](Get-OmniRouteDictValue -Dictionary $requestBody -Name 'stream' -Default $false)
            if ($isStream) {
                $session = Start-OmniRouteStream -Config $Config -State $State -RequestBody $requestBody -Endpoint $endpoint -RequestId $requestId
                if (-not $session.success) {
                    $errorResult = $session.errorResult
                    Write-OmniRouteHttpResponse -Context $Context -StatusCode $errorResult.statusCode -Body $errorResult.body -RequestId $requestId
                    return
                }
                $response = $Context.Response
                $response.StatusCode = 200
                $response.ContentType = 'text/event-stream; charset=utf-8'
                $response.Headers['Cache-Control'] = 'no-cache, no-transform'
                $response.Headers['Connection'] = 'keep-alive'
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

            $result = Invoke-OmniRouteRequest -Config $Config -State $State -RequestBody $requestBody -Endpoint $endpoint -RequestId $requestId
            Write-OmniRouteHttpResponse -Context $Context -StatusCode $result.statusCode -Body $result.body -RequestId $requestId
            return
        }

        $notFound = New-OmniRouteErrorResult -Status 404 -Type 'routing_error' -Code 'not_found' -Message "No route for $method $path." -RequestId $requestId
        Write-OmniRouteHttpResponse -Context $Context -StatusCode 404 -Body $notFound.body -RequestId $requestId
    }
    catch [System.IO.InvalidDataException] {
        $errorResult = New-OmniRouteErrorResult -Status 413 -Type 'config_error' -Code 'request_too_large' -Message $_.Exception.Message -RequestId $requestId
        Write-OmniRouteHttpResponse -Context $Context -StatusCode 413 -Body $errorResult.body -RequestId $requestId
    }
    catch {
        $message = $_.Exception.Message
        $isClientError = $message -match '^(Invalid request|Unsupported parameter)'
        if ($isClientError) {
            $errorResult = New-OmniRouteErrorResult -Status 400 -Type 'routing_error' -Code 'invalid_request' -Message $message -RequestId $requestId
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 400 -Body $errorResult.body -RequestId $requestId
        }
        else {
            if ($DebugMode) { Write-OmniRouteLog -Level ERROR -Message 'internal_error' -Data @{ req = $requestId; detail = $_.Exception.ToString() + [Environment]::NewLine + $_.ScriptStackTrace } -Format $Config.logging.format }
            else { Write-OmniRouteLog -Level ERROR -Message 'internal_error' -Data @{ req = $requestId; detail = $message } -Format $Config.logging.format }
            $errorResult = New-OmniRouteErrorResult -Status 500 -Type 'internal_error' -Code 'internal_error' -Message 'Internal server error.' -RequestId $requestId
            Write-OmniRouteHttpResponse -Context $Context -StatusCode 500 -Body $errorResult.body -RequestId $requestId
        }
    }
    finally {
        $State.activeRequests--
    }
}

function Start-OmniRouteServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$ConfigPath = $Config.sourcePath,
        [bool]$DebugMode = $false,
        [int]$MaxConcurrentRequests = 64,
        [AllowNull()][object]$State = $null
    )

    if ($null -eq $State) { $State = New-OmniRouteState }
    if (-not [System.Net.HttpListener]::IsSupported) { throw 'System.Net.HttpListener is not supported on this platform.' }
    $hostName = [string]$Config.listen
    if ($hostName -eq '0.0.0.0' -or $hostName -eq '*') {
        $prefix = "http://*:$($Config.port)/"
        Write-OmniRouteLog -Level WARN -Message 'network_exposure' -Data @{ listen = $hostName; port = $Config.port; warning = 'OmniRoute-PS is reachable on the local network.' } -Format $Config.logging.format
    }
    elseif ($hostName -eq '::') {
        $prefix = "http://[$hostName]:$($Config.port)/"
    }
    else {
        $prefix = "http://$hostName`:$($Config.port)/"
    }

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    $jobs = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    $root = Split-Path -Parent $PSScriptRoot
    $handler = {
        param($Context, $Root, $Config, $State, $DebugMode)
        try {
            . (Join-Path $Root 'src/Logging.ps1')
            . (Join-Path $Root 'src/Config.ps1')
            . (Join-Path $Root 'src/Transport.ps1')
            . (Join-Path $Root 'src/Adapters.ps1')
            . (Join-Path $Root 'src/Health.ps1')
            . (Join-Path $Root 'src/Router.ps1')
            . (Join-Path $Root 'src/Server.ps1')
            Invoke-OmniRouteHttpContext -Context $Context -Config $Config -State $State -DebugMode $DebugMode
        }
        catch {
            try {
                Write-OmniRouteLog -Level ERROR -Message 'worker_exception' -Data @{ detail = $_.Exception.ToString() + [Environment]::NewLine + $_.ScriptStackTrace; requestPath = $Context.Request.Url.AbsolutePath } -Format 'console'
            }
            catch { }
            try {
                $id = New-OmniRouteRequestId
                $errorResult = New-OmniRouteErrorResult -Status 500 -Type 'internal_error' -Code 'worker_failure' -Message 'Internal worker failure.' -RequestId $id
                Write-OmniRouteHttpResponse -Context $Context -StatusCode 500 -Body $errorResult.body -RequestId $id
            }
            catch { }
        }
    }

    try {
        $listener.Start()
        Write-OmniRouteLog -Level INFO -Message 'server_start' -Data @{ listen = $hostName; port = $Config.port; config = $ConfigPath; providers = $Config.providers.Count } -Format $Config.logging.format
        Write-Host "OmniRoute-PS listening on $prefix" -ForegroundColor Green
        Write-Host "Config: $ConfigPath"
        Write-Host 'Press Ctrl+C to stop.'

        while ($true) {
            $completed = @($jobs.ToArray())
            foreach ($job in $completed) {
                if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
                    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
                    $jobs.Remove($job)
                }
            }
            if ($jobs.Count -ge $MaxConcurrentRequests) {
                Start-Sleep -Milliseconds 25
                continue
            }
            $context = $listener.GetContextAsync().GetAwaiter().GetResult()
            $job = Start-ThreadJob -ScriptBlock $handler -ArgumentList @($context, $root, $Config, $State, $DebugMode) -Name ('omniroute-' + (New-OmniRouteRequestId))
            [void]$jobs.Add($job)
        }
    }
    finally {
        try { $listener.Stop() } catch { }
        try { $listener.Close() } catch { }
        foreach ($job in @($jobs.ToArray())) {
            try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
        }
        Write-OmniRouteLog -Level INFO -Message 'server_stop' -Data @{ listen = $hostName; port = $Config.port } -Format $Config.logging.format
    }
}
