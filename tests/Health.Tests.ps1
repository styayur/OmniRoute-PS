BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-OmniRouteTestModules
}

Describe 'Circuit breaker and health state' {
    BeforeEach {
        $provider = New-OmniRouteTestProvider -Id primary
        $config = New-OmniRouteTestConfig -Providers @{ primary = $provider } -CircuitFailureThreshold 3 -CircuitOpenSeconds 30
        $state = New-OmniRouteState
    }

    It 'transitions Closed to Open after the configured failure threshold' {
        $error = ConvertTo-OmniRouteUpstreamError -Message 'failed' -Status 503 -Retryable $true
        1..3 | ForEach-Object { Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error }
        Get-OmniCircuitState -State $state -Provider $provider -Config $config | Should -Be 'Open'
    }

    It 'transitions Open to HalfOpen after the open duration' {
        $error = ConvertTo-OmniRouteUpstreamError -Message 'failed' -Status 503 -Retryable $true
        1..3 | ForEach-Object { Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error }
        $runtime = Get-OmniProviderRuntimeState -State $state -ProviderId $provider.id
        $runtime.openedAt = [DateTimeOffset]::UtcNow.AddSeconds(-31)
        Get-OmniCircuitState -State $state -Provider $provider -Config $config | Should -Be 'HalfOpen'
    }

    It 'closes after a successful HalfOpen probe' {
        $error = ConvertTo-OmniRouteUpstreamError -Message 'failed' -Status 503 -Retryable $true
        1..3 | ForEach-Object { Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error }
        $runtime = Get-OmniProviderRuntimeState -State $state -ProviderId $provider.id
        $runtime.openedAt = [DateTimeOffset]::UtcNow.AddSeconds(-31)
        Test-OmniCircuitAllowsRequest -State $state -Provider $provider -Config $config | Should -BeTrue
        Set-OmniProviderSuccess -State $state -Provider $provider -LatencyMs 42
        Get-OmniCircuitState -State $state -Provider $provider -Config $config | Should -Be 'Closed'
    }

    It 'reopens after a failed HalfOpen probe' {
        $error = ConvertTo-OmniRouteUpstreamError -Message 'failed' -Status 503 -Retryable $true
        1..3 | ForEach-Object { Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error }
        $runtime = Get-OmniProviderRuntimeState -State $state -ProviderId $provider.id
        $runtime.openedAt = [DateTimeOffset]::UtcNow.AddSeconds(-31)
        Test-OmniCircuitAllowsRequest -State $state -Provider $provider -Config $config | Should -BeTrue
        Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error
        Get-OmniCircuitState -State $state -Provider $provider -Config $config | Should -Be 'Open'
    }

    It 'reports an untested router as ok rather than degraded' {
        $report = Get-OmniRouteHealthReport -Config $config -State $state
        $report.status | Should -Be 'ok'
    }
}
