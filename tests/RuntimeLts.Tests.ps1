#Requires -Version 7.6

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
        Import-Module (Join-Path $repoRoot 'scripts/AutomationRuntimeContract.psm1') -Force
        $runtimeContract = Get-AutomationRuntimeContract
        $payload = & ([scriptblock]::Create($runtime[0].Extent.Text))
        $payload.language | Should -Be 'PowerShell'
        $payload.version | Should -Be '7.6'
        $runtimeContract.Spec.runtimeEnvironmentName | Should -Be 'PowerShell-76-AzAccounts'
        $publisher | Should -Match '\$runtimeEnvironmentName = \$runtimeContract\.Spec\.runtimeEnvironmentName'
        $publisher | Should -Match 'runtimeEnvironment = \$runtimeEnvironmentName'
        $publisher | Should -Not -Match 'PowerShell-74-AzAccounts|version = ''7\.4'''
    }

    It 'builds the hash-locked upstream runbook without cloud operations and reports the new binding' {
        $result = @(& $publisherPath -BuildOnly) | Where-Object { $_.RuntimeEnvironmentName }
        $result.Count | Should -Be 1
        $result.RuntimeEnvironmentName | Should -Be 'PowerShell-76-AzAccounts'
        $result.UpstreamCommit | Should -Be '69e5cfd53e5f1e6c8b762c86cb5b3967b3359e98'
        Test-Path $result.RunbookScriptPath | Should -BeTrue
        $ast = [Management.Automation.Language.Parser]::ParseFile($result.RunbookScriptPath, [ref]$null, [ref]$null)
        $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'UseBoundedPublicationMetadataReader' })
        $parameter.Count | Should -Be 1
        $parameter[0].StaticType | Should -Be ([bool])
        $parameter[0].DefaultValue.SafeGetValue() | Should -BeFalse
        foreach ($attribute in $parameter[0].Attributes) {
            if ($attribute -is [Management.Automation.Language.AttributeAst]) {
                foreach ($argument in @($attribute.NamedArguments | Where-Object ArgumentName -EQ 'Mandatory')) {
                    $argument.Argument.SafeGetValue() | Should -BeFalse
                }
            }
        }
    }

    It 'rejects missing or unexpected generated runbook parameters: <_>' -ForEach @('MissingStorage', 'MissingOptional', 'Unexpected') {
        $case = $_
        $fixture = Join-Path $TestDrive $case
        New-Item (Join-Path $fixture 'build/azure'), (Join-Path $fixture 'azure') -ItemType Directory -Force | Out-Null
        "Write-Output 'Runbook shared-helper fingerprint: $('a' * 64)'" | Set-Content (Join-Path $fixture 'build/azure/Build-Runbook.ps1')
        $source = 'param([string]$StorageAccountName,[string]$DashboardDeliveryMode,[bool]$IncludeAdvancedHunting,[bool]$UseExistingExportsOnly,[bool]$UseDirectMergeDeviceLookup,[bool]$UseBoundedPublicationMetadataReader=$false,[string]$Export)'
        switch ($case) {
            'MissingStorage' { $source = $source.Replace('[string]$StorageAccountName,', '') }
            'MissingOptional' { $source = $source.Replace('[bool]$UseBoundedPublicationMetadataReader=$false,', '') }
            'Unexpected' { $source = $source.Replace('[string]$Export)', '[string]$Export,[bool]$Unexpected)') }
        }
        $source | Set-Content (Join-Path $fixture 'azure/Invoke-DashboardPipeline.ps1')
        & {
            function git { $global:LASTEXITCODE = 0; '69e5cfd53e5f1e6c8b762c86cb5b3967b3359e98' }
            { & $publisherPath -BuildOnly -RepositoryPath $fixture } | Should -Throw '*parameter contract mismatch*'
        }
    }
}
