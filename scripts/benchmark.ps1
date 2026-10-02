#!/usr/bin/env pwsh
#requires -Version 7.4

param(
    [int]$SequentialRequests = 100,
    [int]$ParallelRequests = 20,
    [int]$RoutingIterations = 10000,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/Logging.ps1')
. (Join-Path $root 'src/Config.ps1')
. (Join-Path $root 'src/Transport.ps1')
. (Join-Path $root 'src/Adapters.ps1')
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
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = 'application/json'
                    $context.Response.ContentLength64 = $bytes.Length
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.OutputStream.Close()
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
    if (-not (Wait-BenchmarkEndpoint -Uri "http://127.0.0.1:$mockPort/health")) { throw 'Mock provider did not start.' }

    $configPath = Join-Path $env:TEMP ('omniroute-bench-' + [guid]::NewGuid().ToString('N') + '.json')
    @{
        listen = '127.0.0.1'
        port = $routerPort
        requestTimeoutSeconds = 10
        retry = @{ maxAttempts = 1; baseDelayMs = 0 }
        circuitBreaker = @{ failureThreshold = 5; openSeconds = 30; halfOpenMaxAttempts = 1 }
        providers = @{
            bench = @{
                type = 'custom-openai'
                baseUrl = "http://127.0.0.1:$mockPort/v1"
                priority = 100
                enabled = $true
                timeoutSeconds = 5
                models = @('bench-model')
            }
        }
        routes = @{ '*' = @('bench') }
        aliases = @{ bench = 'bench-model' }
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8

    $startupSamples = [System.Collections.Generic.List[double]]::new()
    1..5 | ForEach-Object {
        $elapsed = Measure-Command {
            & pwsh -NoProfile -File (Join-Path $root 'omniroute.ps1') version -Json | Out-Null
        }
        $startupSamples.Add($elapsed.TotalMilliseconds)
    }

    $config = Get-OmniRouteConfig -Path $configPath
    $state = New-OmniRouteState
    $routingElapsed = Measure-Command {
        1..$RoutingIterations | ForEach-Object {
            $route = Resolve-OmniRouteModel -Config $config -Model 'bench-model'
            $null = Get-OmniRouteCandidates -Config $config -State $state -Route $route
        }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $root 'omniroute.ps1'), 'serve', '-Config', $configPath, '-Port', [string]$routerPort)) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $serverProcess = [System.Diagnostics.Process]::Start($psi)
    $stdoutDrain = $serverProcess.StandardOutput.ReadToEndAsync()
    $stderrDrain = $serverProcess.StandardError.ReadToEndAsync()
    if (-not (Wait-BenchmarkEndpoint -Uri "http://127.0.0.1:$routerPort/health")) { throw 'OmniRoute-PS benchmark server did not start.' }
    [GC]::Collect()
    $idleWorkingSetMb = [Math]::Round($serverProcess.WorkingSet64 / 1MB, 1)

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(180)
    $requestUri = "http://127.0.0.1:$routerPort/v1/chat/completions"
    try {
        $sequentialElapsed = Measure-Command {
            for ($i = 0; $i -lt $SequentialRequests; $i++) {
                $content = [System.Net.Http.StringContent]::new('{"model":"bench-model","messages":[{"role":"user","content":"benchmark"}]}', [System.Text.Encoding]::UTF8, 'application/json')
                $response = $client.PostAsync($requestUri, $content).GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) { throw "Sequential request failed with HTTP $([int]$response.StatusCode)." }
                $null = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $response.Dispose()
                $content.Dispose()
            }
        }

        $parallelContent = [System.Collections.Generic.List[object]]::new()
        $parallelTasks = [System.Collections.Generic.List[object]]::new()
        $parallelElapsed = Measure-Command {
            for ($i = 0; $i -lt $ParallelRequests; $i++) {
                $content = [System.Net.Http.StringContent]::new('{"model":"bench-model","messages":[{"role":"user","content":"benchmark"}]}', [System.Text.Encoding]::UTF8, 'application/json')
                $parallelContent.Add($content)
                $parallelTasks.Add($client.PostAsync($requestUri, $content))
            }
            [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$parallelTasks.ToArray())
            foreach ($task in $parallelTasks) {
                $response = $task.GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) { throw "Parallel request failed with HTTP $([int]$response.StatusCode)." }
                $null = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $response.Dispose()
            }
        }
        foreach ($content in $parallelContent) { $content.Dispose() }

        [GC]::Collect()
        $loadedWorkingSetMb = [Math]::Round($serverProcess.WorkingSet64 / 1MB, 1)
        $result = [pscustomobject]@{
            timestamp              = [DateTimeOffset]::Now.ToString('o')
            os                     = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
            powerShell             = $PSVersionTable.PSVersion.ToString()
            startupAvgMs           = [Math]::Round(($startupSamples | Measure-Object -Average).Average, 1)
            routingIterations      = $RoutingIterations
            routingAvgMs           = [Math]::Round($routingElapsed.TotalMilliseconds / $RoutingIterations, 4)
            sequentialRequests     = $SequentialRequests
            sequentialAvgMs        = [Math]::Round($sequentialElapsed.TotalMilliseconds / $SequentialRequests, 2)
            parallelRequests       = $ParallelRequests
            parallelTotalMs        = [Math]::Round($parallelElapsed.TotalMilliseconds, 1)
            routerIdleWorkingSetMb = $idleWorkingSetMb
            routerLoadedWorkingSetMb = $loadedWorkingSetMb
        }
        if ($Json) { $result | ConvertTo-Json -Depth 10 } else { $result | Format-List }
    }
    finally {
        $client.Dispose()
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    }
}
finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        [void]$serverProcess.Kill($true)
        [void]$serverProcess.WaitForExit(5000)
    }
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
