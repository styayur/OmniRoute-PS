BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-OmniRouteTestModules
}

Describe 'Configuration validation' {
    BeforeEach {
        $validConfig = [ordered]@{
            listen = '127.0.0.1'
            port = 20128
            requestTimeoutSeconds = 30
            providers = @{
                local = @{
                    type = 'openai'
                    baseUrl = 'http://127.0.0.1:11434/v1'
                    priority = 10
                    enabled = $true
                }
            }
            routes = @{ '*' = @('local') }
            aliases = @{ fast = 'local-model' }
        }
    }

    It 'accepts a valid configuration' {
        $path = Join-Path $TestDrive 'valid.json'
        $validConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeTrue
        $result.errors.Count | Should -Be 0
        $result.config.providers.local.baseUrl | Should -Be 'http://127.0.0.1:11434/v1'
    }

    It 'rejects malformed JSON' {
        $path = Join-Path $TestDrive 'bad.json'
        '{ not json' | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeFalse
        $result.errors[0].message | Should -Match 'JSON is invalid'
    }

    It 'rejects routes that reference missing providers' {
        $validConfig.routes = @{ '*' = @('missing') }
        $path = Join-Path $TestDrive 'missing-provider.json'
        $validConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeFalse
        @($result.errors | ForEach-Object { $_.message }) -join ';' | Should -Match 'does not exist'
    }

    It 'rejects an invalid port' {
        $validConfig.port = 70000
        $path = Join-Path $TestDrive 'bad-port.json'
        $validConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeFalse
        @($result.errors | ForEach-Object { $_.path }) | Should -Contain 'port'
    }

    It 'warns when an apiKeyEnv variable is missing' {
        $envName = 'OMNIROUTE_TEST_MISSING_KEY'
        Remove-Item "Env:$envName" -ErrorAction SilentlyContinue
        $validConfig.providers.local.apiKeyEnv = $envName
        $path = Join-Path $TestDrive 'missing-env.json'
        $validConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeTrue
        @($result.warnings | ForEach-Object { $_.message }) -join ';' | Should -Match $envName
    }

    It 'rejects non-http provider URLs' {
        $validConfig.providers.local.baseUrl = 'file:///tmp/secret'
        $path = Join-Path $TestDrive 'bad-url.json'
        $validConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeFalse
        @($result.errors | ForEach-Object { $_.message }) -join ';' | Should -Match 'absolute http or https'
    }

    It 'rejects literal API keys in config' {
        $validConfig.providers.local.apiKey = 'sk-not-allowed'
        $path = Join-Path $TestDrive 'literal-key.json'
        $validConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeFalse
        @($result.errors | ForEach-Object { $_.message }) -join ';' | Should -Match 'Literal API keys are prohibited'
    }

    It 'defaults CORS to disabled and exposes server limits' {
        $path = Join-Path $TestDrive 'defaults.json'
        $validConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeTrue
        $result.config.http.cors.enabled | Should -BeFalse
        $result.config.http.cors.allowedOrigins.Count | Should -Be 0
        $result.config.server.minWorkers | Should -Be 2
        $result.config.server.maxWorkers | Should -BeGreaterThan 0
        $result.config.server.maxQueuedRequests | Should -Be 64
    }

    It 'rejects an invalid CORS origin' {
        $validConfig.http = @{ cors = @{ enabled = $true; allowedOrigins = @('https://example.com/path') } }
        $path = Join-Path $TestDrive 'bad-cors.json'
        $validConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        $result = Test-OmniRouteConfig -Path $path
        $result.valid | Should -BeFalse
        @($result.errors | ForEach-Object { $_.path }) | Should -Contain 'http.cors.allowedOrigins'
    }
}
