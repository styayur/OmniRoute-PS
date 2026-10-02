BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-OmniRouteTestModules

    $mockPort = Get-OmniRouteTestFreePort
        $serverPort = Get-OmniRouteTestFreePort
    $mockStop = @{ Stop = $false }
    $mockJob = $null
    $serverProcess = $null

    $mockJob = Start-ThreadJob -Name 'omniroute-mock-provider' -ArgumentList @($mockPort, $mockStop) -ScriptBlock {
        param($Port, $Stop)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()
        try {
            while (-not $Stop.Stop) {
                $context = $listener.GetContextAsync().GetAwaiter().GetResult()
                try {
                    $buffer = [byte[]]::new(4096)
                    while ($context.Request.InputStream.Read($buffer, 0, $buffer.Length) -gt 0) { }
                    $path = $context.Request.Url.AbsolutePath
                    $response = $context.Response
                    if ($path -like '/primary/*') {
                        $response.StatusCode = 500
                        $body = '{"error":{"message":"primary failed","type":"server_error"}}'
                    }
                    elseif ($path -like '/rate-limit/*') {
                        $response.StatusCode = 429
                        $body = '{"error":{"message":"rate limited","type":"rate_limit_error"}}'
                    }
                    elseif ($path -like '/timeout/*') {
                        Start-Sleep -Milliseconds 1500
                        $response.StatusCode = 200
                        $body = '{"id":"chatcmpl-timeout","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"late"},"finish_reason":"stop"}]}'
                    }
                    elseif ($path -like '/malformed/*') {
                        $response.StatusCode = 200
                        $body = 'not-json'
                    }
                    elseif ($path -like '/sse/*') {
                        $response.StatusCode = 200
                        $response.ContentType = 'text/event-stream'
                        $response.SendChunked = $true
                        $utf8 = [System.Text.UTF8Encoding]::new($false)
                        $chunks = @(
                            ('data: {"id":"chatcmpl-stream","object":"chat.completion.chunk","model":"test-model","choices":[{"index":0,"delta":{"content":"first"},"finish_reason":null}]}' + "`n`n")
                            ('data: {"id":"chatcmpl-stream","object":"chat.completion.chunk","model":"test-model","choices":[{"index":0,"delta":{"content":"second"},"finish_reason":null}]}' + "`n`n")
                            ('data: [DONE]' + "`n`n")
                        )
                        $bytes = $utf8.GetBytes($chunks[0])
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                        Start-Sleep -Milliseconds 650
                        $bytes = $utf8.GetBytes($chunks[1])
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                        $bytes = $utf8.GetBytes($chunks[2])
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                        $response.OutputStream.Close()
                        $response.Close()
                        continue
                    }
                    else {
                        $response.StatusCode = 200
                        $body = '{"id":"chatcmpl-ok","object":"chat.completion","created":1,"model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
                    }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $response.ContentType = 'application/json'
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Close()
                }
                catch {
                    try { $context.Response.Abort() } catch { }
                }
            }
        }
        finally {
            try { $listener.Stop() } catch { }
            try { $listener.Close() } catch { }
        }
    }

    Wait-OmniRouteTestEndpoint -Uri "http://127.0.0.1:$mockPort/health" -TimeoutSeconds 10 | Should -BeTrue

    $providers = @{
        primary    = New-OmniRouteTestProvider -Id primary -BaseUrl "http://127.0.0.1:$mockPort/primary/v1" -Priority 100 -TimeoutSeconds 5
        secondary  = New-OmniRouteTestProvider -Id secondary -BaseUrl "http://127.0.0.1:$mockPort/secondary/v1" -Priority 90 -TimeoutSeconds 5
        rate       = New-OmniRouteTestProvider -Id rate -BaseUrl "http://127.0.0.1:$mockPort/rate-limit/v1" -Priority 100 -TimeoutSeconds 5
        timeout    = New-OmniRouteTestProvider -Id timeout -BaseUrl "http://127.0.0.1:$mockPort/timeout/v1" -Priority 100 -TimeoutSeconds 1
        malformed  = New-OmniRouteTestProvider -Id malformed -BaseUrl "http://127.0.0.1:$mockPort/malformed/v1" -Priority 100 -TimeoutSeconds 5
        refused    = New-OmniRouteTestProvider -Id refused -BaseUrl "http://127.0.0.1:0/v1" -Priority 100 -TimeoutSeconds 2
        sse        = New-OmniRouteTestProvider -Id sse -BaseUrl "http://127.0.0.1:$mockPort/sse/v1" -Priority 100 -TimeoutSeconds 5
    }
    $routes = @{
        'fallback-*'  = @('primary', 'secondary')
        'rate-*'      = @('rate', 'secondary')
        'timeout-*'   = @('timeout')
        'malformed-*' = @('malformed')
        'refused-*'   = @('refused')
        'sse-*'       = @('sse')
        '*'           = @('secondary')
    }
    $config = New-OmniRouteTestConfig -Providers $providers -Routes $routes -Aliases @{ fast = 'secondary-model' }
    $state = New-OmniRouteState

    $serverConfigPath = Join-Path $TestDrive 'integration-config.json'
    @{
        listen = '127.0.0.1'
        port = $serverPort
        requestTimeoutSeconds = 10
        retry = @{ maxAttempts = 1; baseDelayMs = 0 }
        circuitBreaker = @{ failureThreshold = 5; openSeconds = 30; halfOpenMaxAttempts = 1 }
        providers = $providers
        routes = $routes
        aliases = @{ fast = 'secondary-model' }
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $serverConfigPath -Encoding utf8

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    $psi.WorkingDirectory = $script:OmniRouteTestRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $script:OmniRouteTestRoot 'omniroute.ps1'), 'serve', '-Config', $serverConfigPath, '-Port', [string]$serverPort)) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $serverProcess = [System.Diagnostics.Process]::Start($psi)
    Wait-OmniRouteTestEndpoint -Uri "http://127.0.0.1:$serverPort/health" -TimeoutSeconds 15 | Should -BeTrue
}

AfterAll {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill($true)
        $serverProcess.WaitForExit(5000)
    }
    if ($null -ne $serverProcess) { $serverProcess.Dispose() }
    $mockStop.Stop = $true
    if ($null -ne $mockJob) {
        Stop-Job -Job $mockJob -ErrorAction SilentlyContinue
        Remove-Job -Job $mockJob -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Router fallback and transport behavior' {
    It 'returns a normal JSON response' {
        $body = @{ model = 'secondary-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $result = Invoke-OmniRouteRequest -Config $config -State $state -RequestBody $body
        $result.success | Should -BeTrue
        ($result.body | ConvertFrom-Json -AsHashtable).choices[0].message.content | Should -Be 'ok'
    }

    It 'falls back on HTTP 500 in provider order' {
        $body = @{ model = 'fallback-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $result = Invoke-OmniRouteRequest -Config $config -State $state -RequestBody $body
        $result.success | Should -BeTrue
        $result.provider | Should -Be 'secondary'
        $result.attempts | Should -Be 2
    }

    It 'translates a limited Responses API request and response' {
        $responseBody = @{ model = 'secondary-model'; input = 'hello'; instructions = 'be brief'; max_output_tokens = 16 }
        $chatBody = ConvertTo-OmniRouteResponsesChatRequest -RequestBody $responseBody
        $result = Invoke-OmniRouteRequest -Config $config -State $state -RequestBody $chatBody -Endpoint responses
        $result.success | Should -BeTrue
        $result.response.object | Should -Be 'response'
        $result.response.output_text | Should -Be 'ok'
    }

    It 'falls back on HTTP 429' {
        $body = @{ model = 'rate-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $result = Invoke-OmniRouteRequest -Config $config -State $state -RequestBody $body
        $result.success | Should -BeTrue
        $result.provider | Should -Be 'secondary'
    }

    It 'normalizes an upstream timeout' {
        $body = @{ model = 'timeout-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $result = Invoke-OmniRouteRequest -Config $config -State $state -RequestBody $body
        $result.success | Should -BeFalse
        $result.statusCode | Should -Be 504
        ($result.body | ConvertFrom-Json -AsHashtable).error.code | Should -Be 'upstream_timeout'
    }

    It 'does not cache a malformed upstream response' {
        $body = @{ model = 'malformed-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $result = Invoke-OmniRouteRequest -Config $config -State $state -RequestBody $body
        $result.success | Should -BeFalse
        ($result.body | ConvertFrom-Json -AsHashtable).error.code | Should -Be 'malformed_upstream_response'
    }

    It 'reports connection refused without a stack trace' {
        $body = @{ model = 'refused-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $result = Invoke-OmniRouteRequest -Config $config -State $state -RequestBody $body
        $result.success | Should -BeFalse
        $result.body | Should -Not -Match 'at System\.'
        ($result.body | ConvertFrom-Json -AsHashtable).error.code | Should -Be 'upstream_connection_failed'
    }

    It 'streams delayed SSE chunks without buffering the full response' {
        $body = @{ model = 'sse-model'; messages = @(@{ role = 'user'; content = 'hello' }); stream = $true }
        $session = Start-OmniRouteStream -Config $config -State $state -RequestBody $body -Endpoint chat
        $session.success | Should -BeTrue
        $blocks = [System.Collections.Generic.List[object]]::new()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $writer = {
            param([string]$Block)
            $blocks.Add([pscustomobject]@{ elapsedMs = [int]$stopwatch.ElapsedMilliseconds; block = $Block })
        }
        Invoke-OmniRouteStream -Session $session -Writer $writer
        $blocks.Count | Should -BeGreaterThan 2
        $blocks[0].elapsedMs | Should -BeLessThan 500
        $blocks[1].elapsedMs | Should -BeGreaterThan 500
        $blockText = ($blocks | ForEach-Object { $_.block }) -join "`n"
        $blockText | Should -Match 'first'
        $blockText | Should -Match '\[DONE\]'
    }

    It 'cancels the upstream stream when a client write fails' {
        $body = @{ model = 'sse-model'; messages = @(@{ role = 'user'; content = 'hello' }); stream = $true }
        $session = Start-OmniRouteStream -Config $config -State $state -RequestBody $body -Endpoint chat
        $session.success | Should -BeTrue
        $failingWriter = { param([string]$Block) throw [System.IO.IOException]::new('client disconnected') }
        { Invoke-OmniRouteStream -Session $session -Writer $failingWriter } | Should -Not -Throw
        $session.cancelled | Should -BeTrue
    }
}

Describe 'HTTP endpoints' {
    It 'serves health and models' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $health = $client.GetStringAsync("http://127.0.0.1:$serverPort/health").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $models = $client.GetStringAsync("http://127.0.0.1:$serverPort/v1/models").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $health.status | Should -BeIn @('ok', 'degraded')
            @($models.data).Count | Should -BeGreaterThan 0
        }
        finally { $client.Dispose() }
    }

    It 'serves a non-streaming OpenAI-compatible completion through fallback' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $content = [System.Net.Http.StringContent]::new('{"model":"fallback-model","messages":[{"role":"user","content":"hello"}]}', [System.Text.Encoding]::UTF8, 'application/json')
            $response = $client.PostAsync("http://127.0.0.1:$serverPort/v1/chat/completions", $content).GetAwaiter().GetResult()
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            [int]$response.StatusCode | Should -Be 200
            ($text | ConvertFrom-Json -AsHashtable).choices[0].message.content | Should -Be 'ok'
        }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $content) { $content.Dispose() }
            $client.Dispose()
        }
    }

    It 'serves the limited Responses API endpoint' {
        $client = [System.Net.Http.HttpClient]::new()
        $content = $null
        $response = $null
        try {
            $content = [System.Net.Http.StringContent]::new('{"model":"secondary-model","input":"hello"}', [System.Text.Encoding]::UTF8, 'application/json')
            $response = $client.PostAsync("http://127.0.0.1:$serverPort/v1/responses", $content).GetAwaiter().GetResult()
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            [int]$response.StatusCode | Should -Be 200
            ($text | ConvertFrom-Json -AsHashtable).output_text | Should -Be 'ok'
        }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $content) { $content.Dispose() }
            $client.Dispose()
        }
    }

    It 'serves real SSE over HTTP before the upstream finishes' {
        $client = [System.Net.Http.HttpClient]::new()
        $request = $null
        $response = $null
        $reader = $null
        try {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "http://127.0.0.1:$serverPort/v1/chat/completions")
            $request.Content = [System.Net.Http.StringContent]::new('{"model":"sse-model","messages":[{"role":"user","content":"hello"}],"stream":true}', [System.Text.Encoding]::UTF8, 'application/json')
            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $reader = [System.IO.StreamReader]::new($response.Content.ReadAsStream())
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $lines = [System.Collections.Generic.List[string]]::new()
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $lines.Add($line)
                if ($line -match 'first') { break }
            }
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 500
            ($lines -join "`n") | Should -Match 'first'
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $request) { $request.Dispose() }
            $client.Dispose()
        }
    }
}
