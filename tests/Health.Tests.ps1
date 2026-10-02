BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-OmniRouteTestModules
}

Describe 'Circuit breaker and health state' {
    BeforeEach {
        $provider = New-OmniRouteTestProvider -Id primary
        $config = New-OmniRouteTestConfig -Providers @{ primary = $provider } -CircuitFailureThreshold 3 -CircuitOpenSeconds 30
        $state = New-OmniRouteState
        $state.initialized = $true
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

    It 'opens the circuit for provider availability failures' {
        $error = ConvertTo-OmniRouteUpstreamError -Message 'unavailable' -Status 503 -Retryable $true
        1..3 | ForEach-Object { Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error }
        Get-OmniCircuitState -State $state -Provider $provider -Config $config | Should -Be 'Open'
        (Get-OmniRouteMetric -State $state -Name 'omniroute_circuit_open_total') | Should -BeGreaterThan 0
    }

    It 'does not open the circuit for authentication errors' {
        $error = ConvertTo-OmniRouteUpstreamError -Message 'invalid key' -Status 401
        1..5 | ForEach-Object { Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error }
        Get-OmniCircuitState -State $state -Provider $provider -Config $config | Should -Be 'Closed'
        (Get-OmniProviderRuntimeState -State $state -ProviderId $provider.id).availability | Should -Be 'auth_error'
    }

    It 'records rate limits as a temporary penalty instead of downtime' {
        $error = ConvertTo-OmniRouteUpstreamError -Message 'rate limited' -Status 429 -Retryable $true
        Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error
        Get-OmniCircuitState -State $state -Provider $provider -Config $config | Should -Be 'Closed'
        (Get-OmniProviderRuntimeState -State $state -ProviderId $provider.id).availability | Should -Be 'rate_limited'
        (Get-OmniRouteRateLimitPenalty -State $state -Provider $provider) | Should -BeGreaterThan 0
    }

    It 'records model compatibility errors without poisoning provider health' {
        $provider.models = @('known-model')
        $error = ConvertTo-OmniRouteUpstreamError -Message 'model not found' -Status 404
        $error | Add-Member -NotePropertyName model -NotePropertyValue 'missing-model'
        Set-OmniProviderFailure -State $state -Provider $provider -Config $config -Error $error
        Get-OmniCircuitState -State $state -Provider $provider -Config $config | Should -Be 'Closed'
        (Test-OmniProviderModelCompatible -State $state -Provider $provider -Model 'missing-model') | Should -BeFalse
        (Test-OmniProviderModelCompatible -State $state -Provider $provider -Model 'known-model') | Should -BeTrue
    }
}
