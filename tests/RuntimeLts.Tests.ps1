Describe 'Wrapper hosted PowerShell LTS runtime' {
    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..'
        $bicep = Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw
        $publisherPath = Join-Path $repoRoot 'scripts/Publish-AutomationRunbook.ps1'
        $publisher = Get-Content $publisherPath -Raw
    }

    It 'selects PowerShell 7.6 for the existing Flex worker' {
        $bicep | Should -Match "@allowed\(\[\s*'7\.6'\s*\]\)\s*param functionRuntimeVersion string = '7\.6'"
        $compute = Get-Content (Join-Path $repoRoot 'infra/modules/compute-functionapp.bicep') -Raw
        $compute | Should -Match "name: 'FC1'"
        $compute | Should -Match 'version: functionRuntimeVersion'
    }

    It 'creates a distinct 7.6 Automation environment and explicitly binds the runbook' {
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($publisherPath, [ref]$null, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $runtime = @($ast.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.HashtableAst]) { return $false }
            $keys = @($node.KeyValuePairs | ForEach-Object { $_.Item1.Value })
            return 'language' -in $keys -and 'version' -in $keys
        }, $true))
        $runtime.Count | Should -Be 1
        $payload = & ([scriptblock]::Create($runtime[0].Extent.Text))
        $payload.language | Should -Be 'PowerShell'
        $payload.version | Should -Be '7.6'
        $publisher | Should -Match "\`$runtimeEnvironmentName = 'PowerShell-76-AzAccounts'"
        $publisher | Should -Match 'runtimeEnvironment = \$runtimeEnvironmentName'
        $publisher | Should -Not -Match 'PowerShell-74-AzAccounts|version = ''7\.4'''
    }

    It 'builds the hash-locked upstream runbook without cloud operations and reports the new binding' {
        $result = @(& $publisherPath -BuildOnly) | Where-Object { $_.RuntimeEnvironmentName }
        $result.Count | Should -Be 1
        $result.RuntimeEnvironmentName | Should -Be 'PowerShell-76-AzAccounts'
        $result.UpstreamCommit | Should -Be '28c68b4ea5521f834884a8f7aad9cfb38f1588b8'
        Test-Path $result.RunbookScriptPath | Should -BeTrue
    }
}
