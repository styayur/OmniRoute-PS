BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
}

Describe 'Repository and runtime audit' {
    It 'uses one version source at 0.2.0' {
        . (Join-Path $root 'src/Version.ps1')
        Get-OmniRouteVersion | Should -Be '0.2.0'
        (Get-Content -LiteralPath (Join-Path $root 'omniroute.ps1') -Raw) | Should -Not -Match "0\.1\.0"
    }

    It 'does not use ThreadJob-per-request in the server' {
        $server = Get-Content -LiteralPath (Join-Path $root 'src/Server.ps1') -Raw
        $server | Should -Not -Match 'Start-ThreadJob'
        $server | Should -Not -Match 'Start-Job'
    }

    It 'uses a reusable RunspacePool in the server' {
        $server = Get-Content -LiteralPath (Join-Path $root 'src/Server.ps1') -Raw
        $server | Should -Match 'CreateRunspacePool'
        $server | Should -Match 'ImportPSModule'
        $server | Should -Not -Match '\. \(Join-Path \$Root ''src/'
    }

    It 'contains a valid JSON schema' {
        $schemaPath = Join-Path $root 'schemas/omniroute.schema.json'
        Test-Path -LiteralPath $schemaPath -PathType Leaf | Should -BeTrue
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties.server | Should -Not -BeNullOrEmpty
        $schema.properties.http | Should -Not -BeNullOrEmpty
        $schema.properties.providers | Should -Not -BeNullOrEmpty
    }

    It 'contains no TODO, FIXME, or HACK markers' {
        $files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notmatch '\\.git\\' -and $_.Name -ne 'Audit.Tests.ps1' }
        $matches = @($files | Select-String -Pattern 'TODO|FIXME|HACK' -ErrorAction SilentlyContinue)
        $matches.Count | Should -Be 0
    }
}
