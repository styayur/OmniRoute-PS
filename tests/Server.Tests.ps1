BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-OmniRouteTestModules
}

Describe 'RunspacePool server lifecycle' {
    It 'starts with pooled workers, enforces the worker bound, and shuts down within the grace period' {
        $port = Get-OmniRouteTestFreePort
        $provider = New-OmniRouteTestProvider -Id primary
        $config = New-OmniRouteTestConfig -Providers @{ primary = $provider }
        $config.port = $port
        $config.server = @{ minWorkers = 1; maxWorkers = 2; maxQueuedRequests = 0; shutdownGraceSeconds = 1 }
        $state = New-OmniRouteState
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $pipeline = [System.Management.Automation.PowerShell]::Create()
        $pipeline.Runspace = $runspace
        $runspace.Open()
        [void]$pipeline.AddScript({
            param($Root, $Config, $State)
            Set-Location $Root
            Import-Module (Join-Path $Root 'src/OmniRoute.psm1') -Force
            Start-OmniRouteServer -Config $Config -ConfigPath 'test-config' -State $State
        }).AddArgument($script:OmniRouteTestRoot).AddArgument($config).AddArgument($state)
        $async = $pipeline.BeginInvoke()
        try {
            Wait-OmniRouteTestEndpoint -Uri "http://127.0.0.1:$port/health/live" -TimeoutSeconds 10 | Should -BeTrue
            (Invoke-RestMethod "http://127.0.0.1:$port/health/live" -TimeoutSec 5).status | Should -Be 'ok'
            $health = Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 5
            $health.workers.active | Should -BeLessThan 3
            $health.workers.available | Should -BeGreaterThan -1
            $state.shuttingDown = $true
            ($async.AsyncWaitHandle.WaitOne(5000)) | Should -BeTrue
            $pipeline.EndInvoke($async) | Out-Null
        }
        finally {
            if (-not $async.IsCompleted) { try { $pipeline.Stop() } catch { } }
            $pipeline.Dispose()
            try { $runspace.Close() } catch { }
            $runspace.Dispose()
        }
    }
}
