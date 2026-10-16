BeforeAll {
    $installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/install.ps1'
}

Describe 'Installer recovery and portable launcher' {
    It 'runs the generated portable launcher from its installed bin directory' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$null)
        $assignment = $ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$shellLauncher'
        }, $true)
        $launcherText = & ([scriptblock]::Create($assignment.Right.Extent.Text))
        $bin = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'bin')
        Set-Content (Join-Path $TestDrive 'omniroute.ps1') 'param([string]$Value) Write-Output "entry:$Value"; exit 7'
        $launcherPath = Join-Path $bin 'omniroute.ps1'
        Set-Content $launcherPath $launcherText
        $output = & pwsh -NoProfile -File $launcherPath 'argument with spaces'
        $LASTEXITCODE | Should -Be 7
        $output | Should -Be 'entry:argument with spaces'
    }

    It 'restores the original installation when staging cannot be moved into place' {
        $testInstallRoot = Join-Path $HOME ('.omniroute-test-' + [guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory -Path $testInstallRoot, $sourceRoot | Out-Null
        Set-Content (Join-Path $testInstallRoot 'original.txt') 'keep me'
        Set-Content (Join-Path $sourceRoot 'omniroute.ps1') 'exit 0'
        Mock Move-Item {
            param($LiteralPath, $Destination)
            if ((Split-Path -Leaf $LiteralPath) -like '.omniroute-staging-*') {
                throw 'synthetic staging move failure'
            }
            [IO.Directory]::Move($LiteralPath, $Destination)
        }
        try {
            { & $installer -SourcePath $sourceRoot -InstallRoot $testInstallRoot -Force } |
                Should -Throw '*synthetic staging move failure*'
            Get-Content (Join-Path $testInstallRoot 'original.txt') | Should -Be 'keep me'
        }
        finally {
            $resolvedTestRoot = [IO.Path]::GetFullPath($testInstallRoot)
            $expectedPrefix = [IO.Path]::GetFullPath($HOME).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar + '.omniroute-test-'
            if (-not $resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected cleanup path' }
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }
}
