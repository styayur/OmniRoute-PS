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
                        $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                        Start-Sleep -Milliseconds 650
                        $bytes = $utf8.GetBytes($chunks[1])
                        $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                        $bytes = $utf8.GetBytes($chunks[2])
                        $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                        $response.OutputStream.Close(); $response.Close()
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
                    $response.OutputStream.Close(); $response.Close()
                }
                catch { try { $context.Response.Abort() } catch { } }
            }
        }
        finally {
            try { $listener.Stop() } catch { }
            try { $listener.Close() } catch { }
        }
    }
    Wait-OmniRouteTestEndpoint -Uri "http://127.0.0.1:$mockPort/health" -TimeoutSeconds 10 | Should -BeTrue

    $providers = @{
        primary   = New-OmniRouteTestProvider -Id primary -BaseUrl "http://127.0.0.1:$mockPort/primary/v1" -Priority 100
        secondary = New-OmniRouteTestProvider -Id secondary -BaseUrl "http://127.0.0.1:$mockPort/secondary/v1" -Priority 90
        rate      = New-OmniRouteTestProvider -Id rate -BaseUrl "http://127.0.0.1:$mockPort/rate-limit/v1" -Priority 100
        timeout   = New-OmniRouteTestProvider -Id timeout -BaseUrl "http://127.0.0.1:$mockPort/timeout/v1" -Priority 100 -TimeoutSeconds 1
        malformed = New-OmniRouteTestProvider -Id malformed -BaseUrl "http://127.0.0.1:$mockPort/malformed/v1" -Priority 100
        refused   = New-OmniRouteTestProvider -Id refused -BaseUrl 'http://127.0.0.1:0/v1' -Priority 100 -TimeoutSeconds 2
        slow      = New-OmniRouteTestProvider -Id slow -BaseUrl "http://127.0.0.1:$mockPort/timeout/v1" -Priority 100 -TimeoutSeconds 10
        sse       = New-OmniRouteTestProvider -Id sse -BaseUrl "http://127.0.0.1:$mockPort/sse/v1" -Priority 100
    }
    $routes = @{
        'fallback-*'  = @('primary', 'secondary')
        'rate-*'      = @('rate', 'secondary')
        'timeout-*'   = @('timeout')
        'malformed-*' = @('malformed')
        'refused-*'   = @('refused')
        'slow-*'      = @('slow')
        'sse-*'       = @('sse')
        'claude-*'    = @('secondary')
        '*'           = @('secondary')
    }
    $aliases = @{ fast = 'secondary-model'; local = 'secondary-model' }
    $config = New-OmniRouteTestConfig -Providers $providers -Routes $routes -Aliases $aliases
    $state = New-OmniRouteState
    $state.initialized = $true

    $serverConfigPath = Join-Path $TestDrive 'integration-config.json'
    $rawConfig = @{
        listen = '127.0.0.1'
        port = $serverPort
        requestTimeoutSeconds = 10
        server = @{ minWorkers = 1; maxWorkers = 2; maxQueuedRequests = 1; shutdownGraceSeconds = 1 }
        http = @{ cors = @{ enabled = $true; allowedOrigins = @('http://allowed.test') } }
        retry = @{ maxAttempts = 1; baseDelayMs = 0 }
        circuitBreaker = @{ failureThreshold = 5; openSeconds = 30; halfOpenMaxAttempts = 1 }
        logging = @{ level = 'error'; format = 'console' }
        providers = $providers
        routes = $routes
        aliases = $aliases
    }
    $rawConfig | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $serverConfigPath -Encoding utf8

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    $psi.WorkingDirectory = $script:OmniRouteTestRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $script:OmniRouteTestRoot 'omniroute.ps1'), 'serve', '-Config', $serverConfigPath, '-Port', [string]$serverPort)) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $serverProcess = [System.Diagnostics.Process]::Start($psi)
    Wait-OmniRouteTestEndpoint -Uri "http://127.0.0.1:$serverPort/health/live" -TimeoutSeconds 15 | Should -BeTrue
}
Describe 'Router fallback and transport behavior' {
    It 'returns a normal OpenAI-compatible response' {
        $body = @{ model = 'secondary-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $result = Invoke-OmniRouteRequest -Config $config -State $state -Request $ir -InboundProtocol 'openai-chat'
        $result.success | Should -BeTrue
        ($result.body | ConvertFrom-Json -AsHashtable).choices[0].message.content | Should -Be 'ok'
    }

    It 'falls back on HTTP 500 in provider order' {
        $body = @{ model = 'fallback-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $result = Invoke-OmniRouteRequest -Config $config -State $state -Request $ir -InboundProtocol 'openai-chat'
        $result.success | Should -BeTrue
        $result.provider | Should -Be 'secondary'
        $result.attempts | Should -Be 2
    }

    It 'falls back on HTTP 429 and records a temporary rate-limit penalty' {
        $body = @{ model = 'rate-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $result = Invoke-OmniRouteRequest -Config $config -State $state -Request $ir -InboundProtocol 'openai-chat'
        $result.success | Should -BeTrue
        $result.provider | Should -Be 'secondary'
        (Get-OmniRouteRateLimitPenalty -State $state -Provider $providers['rate']) | Should -BeGreaterThan 0
    }

    It 'normalizes an upstream timeout' {
        $body = @{ model = 'timeout-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $result = Invoke-OmniRouteRequest -Config $config -State $state -Request $ir -InboundProtocol 'openai-chat'
        $result.success | Should -BeFalse
        $result.statusCode | Should -Be 504
        ($result.body | ConvertFrom-Json -AsHashtable).error.code | Should -Be 'upstream_timeout'
    }

    It 'rejects malformed upstream JSON without a stack trace' {
        $body = @{ model = 'malformed-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $result = Invoke-OmniRouteRequest -Config $config -State $state -Request $ir -InboundProtocol 'openai-chat'
        $result.success | Should -BeFalse
        ($result.body | ConvertFrom-Json -AsHashtable).error.code | Should -Be 'malformed_upstream_response'
        $result.body | Should -Not -Match 'at System\.'
    }

    It 'reports connection refused as a provider availability error' {
        $body = @{ model = 'refused-model'; messages = @(@{ role = 'user'; content = 'hello' }) }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $result = Invoke-OmniRouteRequest -Config $config -State $state -Request $ir -InboundProtocol 'openai-chat'
        $result.success | Should -BeFalse
        (Get-OmniRouteErrorClass -Error (ConvertTo-OmniRouteUpstreamError -Message 'refused' -Code 'upstream_connection_failed' -Retryable $true)) | Should -Be 'connection_failure'
    }

    It 'streams delayed OpenAI SSE chunks without full buffering' {
        $body = @{ model = 'sse-model'; messages = @(@{ role = 'user'; content = 'hello' }); stream = $true }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $session = Start-OmniRouteStream -Config $config -State $state -Request $ir -InboundProtocol 'openai-chat'
        $session.success | Should -BeTrue
        $blocks = [System.Collections.Generic.List[object]]::new()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $writer = { param([string]$Block) $blocks.Add([pscustomobject]@{ elapsedMs = [int]$stopwatch.ElapsedMilliseconds; block = $Block }) }
        Invoke-OmniRouteStream -Session $session -Writer $writer
        $blocks.Count | Should -BeGreaterThan 2
        $blocks[0].elapsedMs | Should -BeLessThan 500
        $blocks[1].elapsedMs | Should -BeGreaterThan 500
        ($blocks | ForEach-Object { $_.block }) -join "`n" | Should -Match '\[DONE\]'
    }

    It 'cancels the upstream stream when a client write fails' {
        $body = @{ model = 'sse-model'; messages = @(@{ role = 'user'; content = 'hello' }); stream = $true }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $session = Start-OmniRouteStream -Config $config -State $state -Request $ir -InboundProtocol 'openai-chat'
        $session.success | Should -BeTrue
        $failingWriter = { param([string]$Block) throw [System.IO.IOException]::new('client disconnected') }
        { Invoke-OmniRouteStream -Session $session -Writer $failingWriter } | Should -Not -Throw
        $session.cancelled | Should -BeTrue
    }
}
Describe 'HTTP endpoints and server concurrency' {
    BeforeEach {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(15)
    }
    AfterEach {
        $client.Dispose()
    }

    It 'serves liveness, readiness, full health, and Prometheus metrics' {
        $live = $client.GetStringAsync("http://127.0.0.1:$serverPort/health/live").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        $ready = $client.GetStringAsync("http://127.0.0.1:$serverPort/health/ready").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        $health = $client.GetStringAsync("http://127.0.0.1:$serverPort/health").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        $probeContent = [System.Net.Http.StringContent]::new('{"model":"secondary-model","messages":[{"role":"user","content":"metrics"}]}', [System.Text.Encoding]::UTF8, 'application/json')
        $probeResponse = $client.PostAsync("http://127.0.0.1:$serverPort/v1/chat/completions", $probeContent).GetAwaiter().GetResult()
        $probeResponse.Dispose(); $probeContent.Dispose()
        $metrics = $client.GetStringAsync("http://127.0.0.1:$serverPort/metrics").GetAwaiter().GetResult()
        $live.status | Should -Be 'ok'
        $ready.ready | Should -BeTrue
        $health.workers | Should -Not -BeNullOrEmpty
        $metrics | Should -Match 'omniroute_requests_total'
        $metrics | Should -Match 'omniroute_requests_active'
        $metrics | Should -Match 'omniroute_provider_requests_total'
    }

    It 'serves OpenAI chat completions' {
        $content = [System.Net.Http.StringContent]::new('{"model":"fallback-model","messages":[{"role":"user","content":"hello"}]}', [System.Text.Encoding]::UTF8, 'application/json')
        $response = $client.PostAsync("http://127.0.0.1:$serverPort/v1/chat/completions", $content).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [int]$response.StatusCode | Should -Be 200
        ($text | ConvertFrom-Json -AsHashtable).choices[0].message.content | Should -Be 'ok'
        $response.Dispose(); $content.Dispose()
    }

    It 'serves the limited Responses API' {
        $content = [System.Net.Http.StringContent]::new('{"model":"secondary-model","input":"hello"}', [System.Text.Encoding]::UTF8, 'application/json')
        $response = $client.PostAsync("http://127.0.0.1:$serverPort/v1/responses", $content).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [int]$response.StatusCode | Should -Be 200
        ($text | ConvertFrom-Json -AsHashtable).output_text | Should -Be 'ok'
        $response.Dispose(); $content.Dispose()
    }

    It 'serves OpenAI SSE over HTTP' {
        $content = [System.Net.Http.StringContent]::new('{"model":"sse-model","messages":[{"role":"user","content":"hello"}],"stream":true}', [System.Text.Encoding]::UTF8, 'application/json')
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "http://127.0.0.1:$serverPort/v1/chat/completions")
        $request.Content = $content
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $reader = [System.IO.StreamReader]::new($response.Content.ReadAsStream())
        $lines = [System.Collections.Generic.List[string]]::new()
        $firstChunkAt = $null
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $reader.EndOfStream -and $stopwatch.ElapsedMilliseconds -lt 10000) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $lines.Add($line)
            if ($null -eq $firstChunkAt -and $line -match 'first') { $firstChunkAt = $stopwatch.ElapsedMilliseconds }
            if ($line -eq 'data: [DONE]') { break }
        }
        [int]$response.StatusCode | Should -Be 200
        $firstChunkAt | Should -BeLessThan 500
        ($lines -join "`n") | Should -Match 'data: \[DONE\]'
        $reader.Dispose(); $response.Dispose(); $request.Dispose()
    }

    It 'serves native Anthropic Messages non-streaming' {
        $payload = '{"model":"claude-test","max_tokens":32,"system":"be brief","messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}]}'
        $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
        $response = $client.PostAsync("http://127.0.0.1:$serverPort/v1/messages", $content).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [int]$response.StatusCode | Should -Be 200
        $json = $text | ConvertFrom-Json -AsHashtable
        $json.type | Should -Be 'message'
        $json.content[0].type | Should -Be 'text'
        $json.stop_reason | Should -Be 'end_turn'
        $json.usage.input_tokens | Should -BeGreaterThan 0
        $response.Dispose(); $content.Dispose()
    }

    It 'serves Anthropic Messages SSE with native event names' {
        $payload = '{"model":"sse-model","max_tokens":32,"messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}],"stream":true}'
        $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "http://127.0.0.1:$serverPort/v1/messages")
        $request.Content = $content
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $reader = [System.IO.StreamReader]::new($response.Content.ReadAsStream())
        $lines = [System.Collections.Generic.List[string]]::new()
        $firstChunkAt = $null
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $reader.EndOfStream -and $stopwatch.ElapsedMilliseconds -lt 10000) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $lines.Add($line)
            if ($null -eq $firstChunkAt -and $line -match 'first') { $firstChunkAt = $stopwatch.ElapsedMilliseconds }
            if ($line -eq 'data: {"type":"message_stop"}') { break }
        }
        [int]$response.StatusCode | Should -Be 200
        $firstChunkAt | Should -BeLessThan 500
        ($lines -join "`n") | Should -Match 'event: message_start'
        ($lines -join "`n") | Should -Match 'event: content_block_delta'
        ($lines -join "`n") | Should -Match 'event: message_stop'
        $reader.Dispose(); $response.Dispose(); $request.Dispose()
    }

    It 'returns structured 503 with Retry-After when the bounded queue is saturated' {
        $payload = '{"model":"slow-model","messages":[{"role":"user","content":"slow"}]}'
        $tasks = [System.Collections.Generic.List[object]]::new()
        $contents = [System.Collections.Generic.List[object]]::new()
        foreach ($i in 1..4) {
            $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
            $contents.Add($content)
            $tasks.Add($client.PostAsync("http://127.0.0.1:$serverPort/v1/chat/completions", $content))
        }
        [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks.ToArray())
        $responses = @($tasks | ForEach-Object { $_.GetAwaiter().GetResult() })
        try {
            @($responses | Where-Object { [int]$_.StatusCode -eq 503 }).Count | Should -BeGreaterThan 0
            $saturated = ($responses | Where-Object { [int]$_.StatusCode -eq 503 } | Select-Object -First 1)
            $saturated.Headers.GetValues('Retry-After') | Should -Contain '1'
            ($saturated.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable).error.code | Should -Be 'worker_pool_saturated'
        }
        finally {
            foreach ($response in $responses) { $response.Dispose() }
            foreach ($content in $contents) { $content.Dispose() }
        }
    }

    It 'enforces explicit CORS allowlists' {
        $allowed = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Options, "http://127.0.0.1:$serverPort/v1/chat/completions")
        $allowed.Headers.Add('Origin', 'http://allowed.test')
        $allowedResponse = $client.SendAsync($allowed).GetAwaiter().GetResult()
        [int]$allowedResponse.StatusCode | Should -Be 204
        $allowedResponse.Headers.GetValues('Access-Control-Allow-Origin') | Should -Contain 'http://allowed.test'

        $denied = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Options, "http://127.0.0.1:$serverPort/v1/chat/completions")
        $denied.Headers.Add('Origin', 'http://denied.test')
        $deniedResponse = $client.SendAsync($denied).GetAwaiter().GetResult()
        [int]$deniedResponse.StatusCode | Should -Be 403
        @($deniedResponse.Headers.Contains('Access-Control-Allow-Origin')) | Should -Not -Contain $true
        $allowedResponse.Dispose(); $allowed.Dispose(); $deniedResponse.Dispose(); $denied.Dispose()
    }

    It 'reloads valid config atomically and retains the prior config after an invalid reload' {
        $before = $client.GetStringAsync("http://127.0.0.1:$serverPort/health").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        $beforeRevision = [int]$before.configRevision
        $rawConfig.aliases['reload-model'] = 'secondary-model'
        $rawConfig | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $serverConfigPath -Encoding utf8
        $reloaded = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 250
            $health = $client.GetStringAsync("http://127.0.0.1:$serverPort/health").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            if ([int]$health.configRevision -gt $beforeRevision) { $reloaded = $true; break }
        }
        $reloaded | Should -BeTrue
        $revisionAfterValidReload = [int]$health.configRevision

        '{ invalid json' | Set-Content -LiteralPath $serverConfigPath -Encoding utf8
        Start-Sleep -Seconds 1
        $healthAfterInvalid = $client.GetStringAsync("http://127.0.0.1:$serverPort/health").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        $healthAfterInvalid.status | Should -BeIn @('ok', 'degraded')
        [int]$healthAfterInvalid.configRevision | Should -Be $revisionAfterValidReload
        $healthAfterInvalid.workers | Should -Not -BeNullOrEmpty
    }

    It 'does not leak workers after requests complete' {
        $healthy = $false
        for ($i = 0; $i -lt 20; $i++) {
            $health = $client.GetStringAsync("http://127.0.0.1:$serverPort/health").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            if ([int]$health.workers.active -le 1 -and [int]$health.workers.queued -eq 0) { $healthy = $true; break }
            Start-Sleep -Milliseconds 100
        }
        $healthy | Should -BeTrue
    }
}

AfterAll {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        try { $serverProcess.Kill($true) } catch { }
        try { [void]$serverProcess.WaitForExit(5000) } catch { }
    }
    if ($null -ne $serverProcess) { $serverProcess.Dispose() }
    $mockStop.Stop = $true
    try { Invoke-WebRequest "http://127.0.0.1:$mockPort/__stop" -TimeoutSec 1 | Out-Null } catch { }
    if ($null -ne $mockJob) {
        Stop-Job -Job $mockJob -ErrorAction SilentlyContinue
        Remove-Job -Job $mockJob -Force -ErrorAction SilentlyContinue
    }
}
