Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:OmniRouteHttpClient = $null
$script:OmniRouteHttpClientLock = [object]::new()

function Get-OmniRouteHttpClient {
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpClient])]
    param()

    if ($null -ne $script:OmniRouteHttpClient) { return $script:OmniRouteHttpClient }
    [System.Threading.Monitor]::Enter($script:OmniRouteHttpClientLock)
    try {
        if ($null -eq $script:OmniRouteHttpClient) {
            $handler = [System.Net.Http.SocketsHttpHandler]::new()
            $handler.AutomaticDecompression =
                [System.Net.DecompressionMethods]::GZip -bor
                [System.Net.DecompressionMethods]::Deflate -bor
                [System.Net.DecompressionMethods]::Brotli
            $handler.PooledConnectionLifetime = [TimeSpan]::FromMinutes(5)
            $client = [System.Net.Http.HttpClient]::new($handler, $true)
            $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
            $client.DefaultRequestHeaders.UserAgent.ParseAdd((Get-OmniRouteUserAgent))
            $script:OmniRouteHttpClient = $client
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:OmniRouteHttpClientLock)
    }
    return $script:OmniRouteHttpClient
}

function Resolve-OmniRouteUri {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Path
    )
    return ($BaseUrl.TrimEnd('/') + '/' + $Path.TrimStart('/'))
}

function New-OmniRouteUpstreamRequest {
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpRequestMessage])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [AllowNull()][object]$Body
    )

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    try {
        foreach ($name in $Headers.Keys) {
            $value = [string]$Headers[$name]
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\r\n]' -or $value -match '[\r\n]') {
                throw "Unsafe HTTP header '$name'."
            }
            if (-not $request.Headers.TryAddWithoutValidation($name, $value)) {
                throw "Failed to add HTTP header '$name'."
            }
        }
        if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
            $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 50 -Compress }
            $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
        }
        return $request
    }
    catch {
        $request.Dispose()
        throw
    }
}

function ConvertTo-OmniRouteUpstreamError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$Status = 0,
        [string]$Code = 'upstream_error',
        [string]$Type = 'provider_error',
        [bool]$Retryable = $false,
        [AllowNull()][Exception]$Exception = $null
    )
    return [pscustomobject]@{
        type      = $Type
        code      = $Code
        message   = $Message
        status    = $Status
        retryable = $Retryable
        exception = $Exception
    }
}

function Get-OmniRouteUpstreamError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Status,
        [AllowNull()][string]$Body
    )

    $message = "Upstream returned HTTP ${Status}."
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        try {
            $parsed = $Body | ConvertFrom-Json -AsHashtable
            $errorValue = Get-OmniRouteDictValue -Dictionary $parsed -Name 'error' -Default $null
            if ($errorValue -is [System.Collections.IDictionary]) {
                $candidate = Get-OmniRouteDictValue -Dictionary $errorValue -Name 'message' -Default $null
                if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { $message = [string]$candidate }
            }
            elseif ($errorValue -is [string] -and -not [string]::IsNullOrWhiteSpace($errorValue)) {
                $message = [string]$errorValue
            }
            else {
                $candidate = Get-OmniRouteDictValue -Dictionary $parsed -Name 'message' -Default $null
                if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { $message = [string]$candidate }
            }
        }
        catch {
            if ($Body.Length -le 240) { $message = "Upstream returned HTTP ${Status}: $Body" }
        }
    }

    $type = 'provider_error'
    $code = 'upstream_http_error'
    if ($Status -in @(401, 403)) { $type = 'authentication_error'; $code = 'upstream_authentication_error' }
    elseif ($Status -eq 429) { $type = 'rate_limit_error'; $code = 'upstream_rate_limit' }
    elseif ($Status -ge 500) { $code = 'upstream_server_error' }
    return ConvertTo-OmniRouteUpstreamError -Message $message -Status $Status -Code $code -Type $type -Retryable ($Status -in @(429, 500, 502, 503, 504))
}

function Invoke-OmniRouteDelay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Milliseconds,
        [Parameter(Mandatory)][System.Threading.CancellationToken]$CancellationToken
    )
    if ($Milliseconds -le 0) { return }
    [System.Threading.Tasks.Task]::Delay($Milliseconds, $CancellationToken).GetAwaiter().GetResult()
}

function Invoke-OmniRouteUpstreamRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [AllowNull()][object]$Body,
        [hashtable]$Retry = @{ maxAttempts = 1; baseDelayMs = 0 },
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    $attempt = 0
    $maxAttempts = [Math]::Max(1, [int]$Retry.maxAttempts)
    $lastError = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $timeoutSeconds = [int]$Provider.timeoutSeconds
        $linked = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
        $linked.CancelAfter([TimeSpan]::FromSeconds($timeoutSeconds))
        $request = $null
        $response = $null
        try {
            $request = New-OmniRouteUpstreamRequest -Method $Method -Uri $Uri -Headers $Headers -Body $Body
            $client = Get-OmniRouteHttpClient
            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseContentRead, $linked.Token).GetAwaiter().GetResult()
            $content = $response.Content.ReadAsStringAsync($linked.Token).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            if ($response.IsSuccessStatusCode) {
                $stopwatch.Stop()
                return [pscustomobject]@{
                    success      = $true
                    status       = $status
                    content      = $content
                    latencyMs    = [int]$stopwatch.ElapsedMilliseconds
                    attempts     = $attempt
                    error        = $null
                    responseBody = $content
                }
            }
            $lastError = Get-OmniRouteUpstreamError -Status $status -Body $content
            $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
            if (-not $lastError.retryable -or $attempt -ge $maxAttempts) { break }
        }
        catch [System.OperationCanceledException] {
            if ($CancellationToken.IsCancellationRequested) { throw }
            $lastError = ConvertTo-OmniRouteUpstreamError -Message "Upstream timed out after $timeoutSeconds seconds." -Code 'upstream_timeout' -Type 'timeout_error' -Retryable $true -Exception $_.Exception
            $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
            if ($attempt -ge $maxAttempts) { break }
        }
        catch [System.Net.Http.HttpRequestException] {
            $lastError = ConvertTo-OmniRouteUpstreamError -Message "Upstream connection failed: $($_.Exception.Message)" -Code 'upstream_connection_failed' -Retryable $true -Exception $_.Exception
            $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
            if ($attempt -ge $maxAttempts) { break }
        }
        catch {
            $lastError = ConvertTo-OmniRouteUpstreamError -Message "Upstream request failed: $($_.Exception.Message)" -Code 'upstream_transport_error' -Exception $_.Exception
            $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
            break
        }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $request) { $request.Dispose() }
            $linked.Dispose()
        }

        $delay = [int]($Retry.baseDelayMs * [Math]::Pow(2, $attempt - 1))
        Invoke-OmniRouteDelay -Milliseconds $delay -CancellationToken $CancellationToken
    }

    $stopwatch.Stop()
    return [pscustomobject]@{
        success      = $false
        status       = if ($null -ne $lastError) { [int]$lastError.status } else { 0 }
        content      = ''
        latencyMs    = [int]$stopwatch.ElapsedMilliseconds
        attempts     = $attempt
        error        = $lastError
        responseBody = ''
    }
}

function Start-OmniRouteUpstreamStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [AllowNull()][object]$Body,
        [hashtable]$Retry = @{ maxAttempts = 1; baseDelayMs = 0 },
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    $attempt = 0
    $maxAttempts = [Math]::Max(1, [int]$Retry.maxAttempts)
    $lastError = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $timeoutSeconds = [int]$Provider.timeoutSeconds
        $linked = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
        $linked.CancelAfter([TimeSpan]::FromSeconds($timeoutSeconds))
        $request = $null
        $response = $null
        $transferred = $false
        try {
            $request = New-OmniRouteUpstreamRequest -Method $Method -Uri $Uri -Headers $Headers -Body $Body
            $client = Get-OmniRouteHttpClient
            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $linked.Token).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            if (-not $response.IsSuccessStatusCode) {
                $errorBody = $response.Content.ReadAsStringAsync($linked.Token).GetAwaiter().GetResult()
                $lastError = Get-OmniRouteUpstreamError -Status $status -Body $errorBody
                $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
                if (-not $lastError.retryable -or $attempt -ge $maxAttempts) {
                    $stopwatch.Stop()
                    return [pscustomobject]@{ success = $false; error = $lastError; latencyMs = [int]$stopwatch.ElapsedMilliseconds; attempts = $attempt }
                }
            }
            else {
                $stream = $response.Content.ReadAsStreamAsync($linked.Token).GetAwaiter().GetResult()
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 8192, $true)
                $stopwatch.Stop()
                $transferred = $true
                return [pscustomobject]@{
                    success            = $true
                    response           = $response
                    request            = $request
                    reader             = $reader
                    status             = $status
                    latencyMs          = [int]$stopwatch.ElapsedMilliseconds
                    attempts           = $attempt
                    error              = $null
                    cancellationSource = $linked
                }
            }
        }
        catch [System.OperationCanceledException] {
            if ($CancellationToken.IsCancellationRequested) { throw }
            $lastError = ConvertTo-OmniRouteUpstreamError -Message "Upstream timed out after $timeoutSeconds seconds." -Code 'upstream_timeout' -Type 'timeout_error' -Retryable $true -Exception $_.Exception
            $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
        }
        catch [System.Net.Http.HttpRequestException] {
            $lastError = ConvertTo-OmniRouteUpstreamError -Message "Upstream connection failed: $($_.Exception.Message)" -Code 'upstream_connection_failed' -Retryable $true -Exception $_.Exception
            $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
        }
        catch {
            $lastError = ConvertTo-OmniRouteUpstreamError -Message "Upstream stream failed: $($_.Exception.Message)" -Code 'upstream_transport_error' -Exception $_.Exception
            $lastError | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
        }
        finally {
            if (-not $transferred) {
                if ($null -ne $response) { $response.Dispose() }
                if ($null -ne $request) { $request.Dispose() }
                if ($null -ne $linked) { $linked.Dispose() }
            }
        }

        if ($attempt -ge $maxAttempts) { break }
        $delay = [int]($Retry.baseDelayMs * [Math]::Pow(2, $attempt - 1))
        Invoke-OmniRouteDelay -Milliseconds $delay -CancellationToken $CancellationToken
    }

    $stopwatch.Stop()
    return [pscustomobject]@{ success = $false; error = $lastError; latencyMs = [int]$stopwatch.ElapsedMilliseconds; attempts = $attempt }
}

function Invoke-OmniRouteUpstreamProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [int]$TimeoutSeconds = 10
    )

    $linked = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $request = $null
    $response = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $request = New-OmniRouteUpstreamRequest -Method 'GET' -Uri $Uri -Headers $Headers
        $client = Get-OmniRouteHttpClient
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseContentRead, $linked.Token).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync($linked.Token).GetAwaiter().GetResult()
        $stopwatch.Stop()
        return [pscustomobject]@{
            success   = $response.IsSuccessStatusCode
            status    = [int]$response.StatusCode
            latencyMs = [int]$stopwatch.ElapsedMilliseconds
            error     = if ($response.IsSuccessStatusCode) { $null } else { Get-OmniRouteUpstreamError -Status ([int]$response.StatusCode) -Body $body }
        }
    }
    catch [System.OperationCanceledException] {
        $stopwatch.Stop()
        return [pscustomobject]@{ success = $false; status = 0; latencyMs = [int]$stopwatch.ElapsedMilliseconds; error = (ConvertTo-OmniRouteUpstreamError -Message 'Probe timed out.' -Code 'upstream_timeout' -Type 'timeout_error' -Retryable $true -Exception $_.Exception) }
    }
    catch {
        $stopwatch.Stop()
        return [pscustomobject]@{ success = $false; status = 0; latencyMs = [int]$stopwatch.ElapsedMilliseconds; error = (ConvertTo-OmniRouteUpstreamError -Message $_.Exception.Message -Code 'upstream_connection_failed' -Retryable $true -Exception $_.Exception) }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        $linked.Dispose()
    }
}