#!/usr/bin/env pwsh
#requires -Version 7.4

param(
    [int]$SequentialRequests = 100,
    [int]$ParallelRequests = 20,
    [int]$ParallelLargeRequests = 50,
    [int]$RoutingIterations = 10000,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/Version.ps1')
. (Join-Path $root 'src/Logging.ps1')
. (Join-Path $root 'src/Config.ps1')
. (Join-Path $root 'src/Protocol.ps1')
. (Join-Path $root 'src/Transport.ps1')
. (Join-Path $root 'src/Adapters.ps1')
. (Join-Path $root 'src/Metrics.ps1')
. (Join-Path $root 'src/Health.ps1')
. (Join-Path $root 'src/Router.ps1')
. (Join-Path $root 'src/Server.ps1')

function Get-BenchmarkFreePort {
    [CmdletBinding()]
    param()
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Wait-BenchmarkEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSeconds = 15)
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

function New-BenchmarkTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Payload,
        [Parameter(Mandatory)][int]$Count
    )
    $contents = [System.Collections.Generic.List[object]]::new()
    $tasks = [System.Collections.Generic.List[object]]::new()
    foreach ($i in 1..$Count) {
        $content = [System.Net.Http.StringContent]::new($Payload, [System.Text.Encoding]::UTF8, 'application/json')
        $contents.Add($content)
        $tasks.Add($Client.PostAsync($Uri, $content))
    }
    return @{ Tasks = $tasks; Contents = $contents }
}

$mockPort = Get-BenchmarkFreePort
$routerPort = Get-BenchmarkFreePort
$mockStop = @{ Stop = $false }
$mockJob = $null
$serverProcess = $null
$stdoutDrain = $null
$stderrDrain = $null

try {
    $mockJob = Start-ThreadJob -ArgumentList @($mockPort, $mockStop) -ScriptBlock {
        param($Port, $Stop)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()
        $body = '{"id":"chatcmpl-bench","object":"chat.completion","created":1,"model":"bench-model","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
        try {
            while (-not $Stop.Stop) {
                $context = $listener.GetContextAsync().GetAwaiter().GetResult()
                try {
                    $buffer = [byte[]]::new(4096)
                    while ($context.Request.InputStream.Read($buffer, 0, $buffer.Length) -gt 0) { }
                    $path = $context.Request.Url.AbsolutePath
                    if ($path -like '/slow/*') {
                        Start-Sleep -Milliseconds 750
                    }
                    if ($path -like '/sse/*') {
                        $response = $context.Response
                        $response.StatusCode = 200
                        $response.ContentType = 'text/event-stream'
                        $response.SendChunked = $true
                        $utf8 = [System.Text.UTF8Encoding]::new($false)
                        $chunks = @(
                            ('data: {"id":"chatcmpl-bench-sse","object":"chat.completion.chunk","model":"bench-model","choices":[{"index":0,"delta":{"content":"first"},"finish_reason":null}]}' + "`n`n")
                            ('data: {"id":"chatcmpl-bench-sse","object":"chat.completion.chunk","model":"bench-model","choices":[{"index":0,"delta":{"content":"second"},"finish_reason":null}]}' + "`n`n")
                            ('data: [DONE]' + "`n`n")
                        )
                        $bytes = $utf8.GetBytes($chunks[0]); $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                        Start-Sleep -Milliseconds 650
                        $bytes = $utf8.GetBytes($chunks[1]); $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                        $bytes = $utf8.GetBytes($chunks[2]); $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                        $response.OutputStream.Close(); $response.Close()
                        continue
                    }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = 'application/json'
                    $context.Response.ContentLength64 = $bytes.Length
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.OutputStream.Close(); $context.Response.Close()
                }
                catch { try { $context.Response.Abort() } catch { } }
            }
        }
        finally {
            try { $listener.Stop() } catch { }
            try { $listener.Close() } catch { }
        }
    }
    if (-not (Wait-BenchmarkEndpoint -Uri "http://127.0.0.1:$mockPort/health")) { throw 'Mock provider did not start.' }

    $configPath = Join-Path $env:TEMP ('omniroute-bench-' + [guid]::NewGuid().ToString('N') + '.json')
    $configObject = @{
        listen = '127.0.0.1'
        port = $routerPort
        requestTimeoutSeconds = 10
        server = @{ minWorkers = 2; maxWorkers = 8; maxQueuedRequests = 64; shutdownGraceSeconds = 1 }
        http = @{ cors = @{ enabled = $false; allowedOrigins = @() } }
        retry = @{ maxAttempts = 1; baseDelayMs = 0 }
        circuitBreaker = @{ failureThreshold = 5; openSeconds = 30; halfOpenMaxAttempts = 1 }
        providers = @{
            bench = @{ type = 'custom-openai'; baseUrl = "http://127.0.0.1:$mockPort/v1"; priority = 100; enabled = $true; timeoutSeconds = 5; models = @('bench-model') }
            sse = @{ type = 'custom-openai'; baseUrl = "http://127.0.0.1:$mockPort/sse/v1"; priority = 90; enabled = $true; timeoutSeconds = 5; models = @('sse-model') }
            slow = @{ type = 'custom-openai'; baseUrl = "http://127.0.0.1:$mockPort/slow/v1"; priority = 80; enabled = $true; timeoutSeconds = 2; models = @('slow-model') }
        }
        routes = @{ 'sse-*' = @('sse'); 'slow-*' = @('slow'); '*' = @('bench') }
        aliases = @{ bench = 'bench-model' }
    }
    $configObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8

    $saturationPort = Get-BenchmarkFreePort
    $saturationConfigPath = Join-Path $env:TEMP ('omniroute-bench-sat-' + [guid]::NewGuid().ToString('N') + '.json')
    $saturationObject = $configObject.Clone()
    $saturationObject.port = $saturationPort
    $saturationObject.server = @{ minWorkers = 2; maxWorkers = 2; maxQueuedRequests = 1; shutdownGraceSeconds = 1 }
    $saturationObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $saturationConfigPath -Encoding utf8

    $startupSamples = [System.Collections.Generic.List[double]]::new()
    1..5 | ForEach-Object {
        $elapsed = Measure-Command { & pwsh -NoProfile -File (Join-Path $root 'omniroute.ps1') version -Json | Out-Null }
        $startupSamples.Add($elapsed.TotalMilliseconds)
    }

    $config = Get-OmniRouteConfig -Path $configPath
    $state = New-OmniRouteState
    $routingRequirement = @{ protocol = 'chat'; tools = $false; vision = $false; streaming = $false }
    $routingElapsed = Measure-Command {
        1..$RoutingIterations | ForEach-Object {
            $route = Resolve-OmniRouteModel -Config $config -Model 'bench-model'
            $null = Get-OmniRouteCandidates -Config $config -State $state -Route $route -Requirement $routingRequirement
        }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $root 'omniroute.ps1'), 'serve', '-Config', $configPath, '-Port', [string]$routerPort)) { [void]$psi.ArgumentList.Add($argument) }
    $serverProcess = [System.Diagnostics.Process]::Start($psi)
    $stdoutDrain = $serverProcess.StandardOutput.ReadToEndAsync()
    $stderrDrain = $serverProcess.StandardError.ReadToEndAsync()
    if (-not (Wait-BenchmarkEndpoint -Uri "http://127.0.0.1:$routerPort/health/live")) { throw 'OmniRoute-PS benchmark server did not start.' }
    [GC]::Collect()
    $idleWorkingSetMb = [Math]::Round($serverProcess.WorkingSet64 / 1MB, 1)

    $saturationPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $saturationPsi.FileName = (Get-Command pwsh).Source
    $saturationPsi.WorkingDirectory = $root
    $saturationPsi.UseShellExecute = $false
    $saturationPsi.CreateNoWindow = $true
    $saturationPsi.RedirectStandardOutput = $true
    $saturationPsi.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $root 'omniroute.ps1'), 'serve', '-Config', $saturationConfigPath, '-Port', [string]$saturationPort)) { [void]$saturationPsi.ArgumentList.Add($argument) }
    $saturationProcess = [System.Diagnostics.Process]::Start($saturationPsi)
    $saturationStdoutDrain = $saturationProcess.StandardOutput.ReadToEndAsync()
    $saturationStderrDrain = $saturationProcess.StandardError.ReadToEndAsync()
    if (-not (Wait-BenchmarkEndpoint -Uri "http://127.0.0.1:$saturationPort/health/live")) { throw 'Saturation benchmark server did not start.' }

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(180)
    $requestUri = "http://127.0.0.1:$routerPort/v1/chat/completions"
    $payload = '{"model":"bench-model","messages":[{"role":"user","content":"benchmark"}]}'
    $slowPayload = '{"model":"slow-model","messages":[{"role":"user","content":"slow"}]}'
    try {
        $sequentialElapsed = Measure-Command {
            for ($i = 0; $i -lt $SequentialRequests; $i++) {
                $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
                $response = $client.PostAsync($requestUri, $content).GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) { throw "Sequential request failed with HTTP $([int]$response.StatusCode)." }
                $null = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $response.Dispose(); $content.Dispose()
            }
        }

        $parallelElapsed = Measure-Command {
            $batch = New-BenchmarkTasks -Client $client -Uri $requestUri -Payload $payload -Count $ParallelRequests
            [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$batch.Tasks.ToArray())
            foreach ($task in $batch.Tasks) { $response = $task.GetAwaiter().GetResult(); if (-not $response.IsSuccessStatusCode) { throw "Parallel request failed." }; $response.Dispose() }
            foreach ($content in $batch.Contents) { $content.Dispose() }
        }

        $parallelLargeElapsed = Measure-Command {
            $batch = New-BenchmarkTasks -Client $client -Uri $requestUri -Payload $payload -Count $ParallelLargeRequests
            [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$batch.Tasks.ToArray())
            foreach ($task in $batch.Tasks) { $response = $task.GetAwaiter().GetResult(); if (-not $response.IsSuccessStatusCode) { throw "Large parallel request failed." }; $response.Dispose() }
            foreach ($content in $batch.Contents) { $content.Dispose() }
        }

        $ssePayload = '{"model":"sse-model","messages":[{"role":"user","content":"benchmark"}],"stream":true}'
        $sseContent = [System.Net.Http.StringContent]::new($ssePayload, [System.Text.Encoding]::UTF8, 'application/json')
        $sseRequest = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $requestUri)
        $sseRequest.Content = $sseContent
        $sseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $sseResponse = $client.SendAsync($sseRequest, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $sseReader = [System.IO.StreamReader]::new($sseResponse.Content.ReadAsStream())
        $firstChunkMs = $null
        while (-not $sseReader.EndOfStream -and $sseStopwatch.ElapsedMilliseconds -lt 5000) {
            $line = $sseReader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -match 'first') { $firstChunkMs = [Math]::Round($sseStopwatch.Elapsed.TotalMilliseconds, 1); break }
        }
        $sseReader.Dispose(); $sseResponse.Dispose(); $sseRequest.Dispose(); $sseContent.Dispose()

        $saturationBatch = New-BenchmarkTasks -Client $client -Uri "http://127.0.0.1:$saturationPort/v1/chat/completions" -Payload $slowPayload -Count 4
        [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$saturationBatch.Tasks.ToArray())
        $saturation503 = 0
        foreach ($task in $saturationBatch.Tasks) {
            $response = $task.GetAwaiter().GetResult()
            if ([int]$response.StatusCode -eq 503) { $saturation503++ }
            $response.Dispose()
        }
        foreach ($content in $saturationBatch.Contents) { $content.Dispose() }

        [GC]::Collect()
        $loadedWorkingSetMb = [Math]::Round($serverProcess.WorkingSet64 / 1MB, 1)
        $serverSource = Get-Content -LiteralPath (Join-Path $root 'src/Server.ps1') -Raw
        $result = [pscustomobject]@{
            timestamp                 = [DateTimeOffset]::Now.ToString('o')
            os                        = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
            powerShell                = $PSVersionTable.PSVersion.ToString()
            version                   = Get-OmniRouteVersion
            startupAvgMs              = [Math]::Round(($startupSamples | Measure-Object -Average).Average, 1)
            routingIterations         = $RoutingIterations
            routingAvgMs              = [Math]::Round($routingElapsed.TotalMilliseconds / $RoutingIterations, 4)
            sequentialRequests        = $SequentialRequests
            sequentialAvgMs          = [Math]::Round($sequentialElapsed.TotalMilliseconds / $SequentialRequests, 2)
            parallelRequests          = $ParallelRequests
            parallelTotalMs           = [Math]::Round($parallelElapsed.TotalMilliseconds, 1)
            parallelLargeRequests     = $ParallelLargeRequests
            parallelLargeTotalMs      = [Math]::Round($parallelLargeElapsed.TotalMilliseconds, 1)
            sseFirstChunkMs           = $firstChunkMs
            saturationAttempts        = 4
            saturation503Count        = $saturation503
            routerIdleWorkingSetMb    = $idleWorkingSetMb
            routerLoadedWorkingSetMb  = $loadedWorkingSetMb
            threadJobPerRequest       = [int]($serverSource -match 'Start-ThreadJob')
            perRequestFullDotSource   = [int]($serverSource -match '\. \(Join-Path \$Root')
        }
        if ($Json) { $result | ConvertTo-Json -Depth 10 } else { $result | Format-List }
    }
    finally {
        $client.Dispose()
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $saturationConfigPath) { Remove-Item -LiteralPath $saturationConfigPath -Force -ErrorAction SilentlyContinue }
    }
}
finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        [void]$serverProcess.Kill($true)
        [void]$serverProcess.WaitForExit(5000)
    }
    if ($null -ne $saturationProcess -and -not $saturationProcess.HasExited) { [void]$saturationProcess.Kill($true); [void]$saturationProcess.WaitForExit(5000) }
    if ($null -ne $saturationProcess) { $saturationProcess.Dispose() }
    if ($null -ne $saturationStdoutDrain) { [void]$saturationStdoutDrain.GetAwaiter().GetResult() }
    if ($null -ne $saturationStderrDrain) { [void]$saturationStderrDrain.GetAwaiter().GetResult() }
    if ($null -ne $serverProcess) { $serverProcess.Dispose() }
    if ($null -ne $stdoutDrain) { [void]$stdoutDrain.GetAwaiter().GetResult() }
    if ($null -ne $stderrDrain) { [void]$stderrDrain.GetAwaiter().GetResult() }
    $mockStop.Stop = $true
    try { Invoke-WebRequest "http://127.0.0.1:$mockPort/__stop" -TimeoutSec 1 | Out-Null } catch { }
    if ($null -ne $mockJob) {
        Stop-Job -Job $mockJob -ErrorAction SilentlyContinue
        Remove-Job -Job $mockJob -Force -ErrorAction SilentlyContinue
    }
}
