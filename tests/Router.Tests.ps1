BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-OmniRouteTestModules
}

Describe 'OmniRoute model resolution and candidate routing' {
    BeforeEach {
        $providers = @{
            openai   = New-OmniRouteTestProvider -Id openai -Priority 100 -Models @('gpt-5')
            deepseek = New-OmniRouteTestProvider -Id deepseek -Priority 80 -Models @('deepseek-chat')
            ollama   = New-OmniRouteTestProvider -Id ollama -Priority 40 -Models @('qwen3:8b')
        }
        $routes = @{
            'gpt-*'      = @('openai', 'deepseek')
            'deepseek-*' = @('deepseek', 'openai')
            'qwen*'      = @('ollama', 'deepseek')
            '*'          = @('deepseek', 'openai', 'ollama')
        }
        $aliases = @{ fast = 'deepseek-chat'; local = 'qwen3:8b' }
        $config = New-OmniRouteTestConfig -Providers $providers -Routes $routes -Aliases $aliases
        $requirement = @{ protocol = 'chat'; tools = $false; vision = $false; streaming = $false }
    }

    It 'matches a wildcard route' {
        $route = Resolve-OmniRouteModel -Config $config -Model 'gpt-5'
        $route.routePattern | Should -Be 'gpt-*'
        $route.model | Should -Be 'gpt-5'
    }

    It 'prefers an exact route over a wildcard route' {
        $config.routes['gpt-5'] = @('deepseek', 'openai')
        $route = Resolve-OmniRouteModel -Config $config -Model 'gpt-5'
        $route.routePattern | Should -Be 'gpt-5'
        $route.routeProviders | Should -Be @('deepseek', 'openai')
    }

    It 'resolves an alias before route matching' {
        $route = Resolve-OmniRouteModel -Config $config -Model 'fast'
        $route.originalModel | Should -Be 'fast'
        $route.model | Should -Be 'deepseek-chat'
        $route.routePattern | Should -Be 'deepseek-*'
    }

    It 'supports explicit provider prefixes including colons in model IDs' {
        $route = Resolve-OmniRouteModel -Config $config -Model 'ollama:qwen3:8b'
        $route.forcedProvider | Should -Be 'ollama'
        $route.model | Should -Be 'qwen3:8b'
    }

    It 'orders candidates by priority and route order' {
        $state = New-OmniRouteState
        $route = Resolve-OmniRouteModel -Config $config -Model 'gpt-5'
        $candidates = Get-OmniRouteCandidates -Config $config -State $state -Route $route -Requirement $requirement
        @($candidates).Count | Should -Be 2
        $candidates[0].provider.id | Should -Be 'openai'
        $candidates[1].provider.id | Should -Be 'deepseek'
    }

    It 'skips a recently unhealthy provider when an alternative is available' {
        $state = New-OmniRouteState
        $primary = $config.providers['ollama']
        Set-OmniProviderFailure -State $state -Provider $primary -Config $config -Error (ConvertTo-OmniRouteUpstreamError -Message 'down' -Status 503 -Retryable $true)
        $route = Resolve-OmniRouteModel -Config $config -Model 'qwen3:8b'
        $candidates = Get-OmniRouteCandidates -Config $config -State $state -Route $route -Requirement $requirement
        @($candidates | ForEach-Object { $_.provider.id }) | Should -Not -Contain 'ollama'
    }

    It 'keeps configured fallback order when priorities are equal' {
        $config.providers['openai'].priority = 50
        $config.providers['deepseek'].priority = 50
        $state = New-OmniRouteState
        $route = Resolve-OmniRouteModel -Config $config -Model 'gpt-5'
        $candidates = Get-OmniRouteCandidates -Config $config -State $state -Route $route -Requirement $requirement
        $candidates[0].provider.id | Should -Be 'openai'
        $candidates[1].provider.id | Should -Be 'deepseek'
    }

    It 'filters providers that do not satisfy tool capabilities' {
        $config.providers['deepseek'].capabilities.tools = $false
        $state = New-OmniRouteState
        $route = Resolve-OmniRouteModel -Config $config -Model 'deepseek-chat'
        $toolRequirement = @{ protocol = 'chat'; tools = $true; vision = $false; streaming = $false }
        $candidates = Get-OmniRouteCandidates -Config $config -State $state -Route $route -Requirement $toolRequirement
        @($candidates | ForEach-Object { $_.provider.id }) | Should -Not -Contain 'deepseek'
        @($candidates | ForEach-Object { $_.provider.id }) | Should -Contain 'openai'
    }
}
