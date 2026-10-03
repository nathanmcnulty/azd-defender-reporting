Describe 'Bundled upstream release' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $fixtureRoot = Join-Path $TestDrive 'wrapper'
        foreach ($directory in @('scripts', 'contracts', 'vendor')) {
            New-Item -Path (Join-Path $fixtureRoot $directory) -ItemType Directory -Force | Out-Null
        }
        foreach ($file in @(
            'scripts/Resolve-UpstreamRepo.ps1', 'scripts/Common-AzurePublish.ps1', 'scripts/Publish-FunctionAppPackage.ps1',
            'contracts/upstream-lock.json', 'contracts/upstream-package.json', 'contracts/released-function-app.json',
            'vendor/defender-reporting-source.zip', 'vendor/function-app-package.zip'
        )) {
            Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $fixtureRoot $file)
        }
        $script:resolver = Join-Path $fixtureRoot 'scripts/Resolve-UpstreamRepo.ps1'
        $script:publisher = Join-Path $fixtureRoot 'scripts/Publish-FunctionAppPackage.ps1'
        $script:archive = Join-Path $fixtureRoot 'vendor/defender-reporting-source.zip'
        $script:functionPackage = Join-Path $fixtureRoot 'vendor/function-app-package.zip'
        $script:originalFunctionPackage = Join-Path $repoRoot 'vendor/function-app-package.zip'
        $script:savedEnvironment = @{}
        foreach ($name in @('DEFENDER_REPORTING_PATH', 'DEFENDER_REPORTING_REPO', 'DEFENDER_REPORTING_REF')) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    AfterAll {
        foreach ($name in $script:savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
    }

    It 'resolves exact build source without invoking Git or a network fetch' {
        & {
            function git { throw 'Git must not be used for the supported bundled path.' }
            $source = & $script:resolver
            $source.Source | Should -Be 'bundled-release'
            $source.MatchesCompatibilityLock | Should -BeTrue
            $source.Commit | Should -Be '28c68b4ea5521f834884a8f7aad9cfb38f1588b8'
            Test-Path -LiteralPath (Join-Path $source.ResolvedPath 'build/Build-FunctionAppPackage.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $source.ResolvedPath 'build/azure/Build-Runbook.ps1') | Should -BeTrue
            (& $script:resolver -RepositoryPath $source.ResolvedPath).Source | Should -Be 'bundled-release'
        }
    }

    It 'uses the exact released Function App package without rebuilding on the publishing host' {
        & {
            function git { throw 'Git must not be used for the supported release package.' }
            $result = & $script:publisher -BuildOnly
            $result.PackageSha256 | Should -Be 'C4FAB102F70CD0FEFE9919D41A049D05A2BE13F371BBC0A12765D2598BE34887'
            $result.PackagePath | Should -Be $script:functionPackage
            $result.UpstreamCommit | Should -Be '28c68b4ea5521f834884a8f7aad9cfb38f1588b8'
        }
    }

    It 'rejects changed released package bytes before publication' {
        try {
            Add-Content -LiteralPath $script:functionPackage -Value 'tampered'
            & {
                function git { throw 'Git must not be used for a tampered release package.' }
                { & $script:publisher -BuildOnly } | Should -Throw '*does not match*'
            }
        }
        finally {
            Copy-Item -LiteralPath $script:originalFunctionPackage -Destination $script:functionPackage -Force
        }
    }

    It 'rejects changed archive bytes before extracting source' {
        Add-Content -LiteralPath $script:archive -Value 'tampered'
        & {
            function git { throw 'Git must not be used for a tampered default bundle.' }
            { & $script:resolver } | Should -Throw '*failed size or SHA-256 verification*'
        }
    }
}
