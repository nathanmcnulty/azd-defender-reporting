#Requires -Version 7.6

Describe 'Compiled Automation storage permissions' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $outputPath = Join-Path $TestDrive 'main.json'
        # Compile the actual module graph, rather than matching source text.
        # Bicep must already be installed; no login, deployment or install occurs.
        & az bicep build --file (Join-Path $repoRoot 'infra/main.bicep') --outfile $outputPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath)) {
            throw 'The compiled RBAC regression requires an installed Bicep CLI.'
        }
        $template = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -AsHashtable
        $storageScope = "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
        $contributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

        function Get-CompiledRoleModule {
            param([string]$Name)
            $matches = @($template.resources | Where-Object { $_.name -eq $Name })
            if ($matches.Count -ne 1) { throw "Expected exactly one '$Name' module." }
            return $matches[0]
        }

        function Get-EnabledCompiledRoleIds {
            param([hashtable]$Module)
            $inner = $Module.properties.template
            foreach ($assignment in $inner.resources) {
                if ($assignment.type -ne 'Microsoft.Authorization/roleAssignments' -or
                    $assignment.condition -notmatch "^\[parameters\('(?<flag>[^']+)'\)\]$") {
                    throw 'Unexpected compiled role resource or condition.'
                }
                $flag = $Matches.flag
                $enabled = if ($Module.properties.parameters.ContainsKey($flag)) {
                    $Module.properties.parameters[$flag].value
                } else {
                    $inner.parameters[$flag].defaultValue
                }
                if ($enabled -isnot [bool]) { throw "Expected a boolean compiled role flag: $flag." }
                if ($assignment.scope -ne $storageScope -or
                    $assignment.properties.principalId -ne "[parameters('principalId')]") {
                    throw 'Compiled role assignment is not bound to the selected storage account and identity.'
                }
                if ($assignment.properties.roleDefinitionId -notmatch "^\[subscriptionResourceId\('Microsoft.Authorization/roleDefinitions', variables\('(?<role>[^']+)'\)\)\]$") {
                    throw 'Unexpected compiled role definition binding.'
                }
                $roleId = $inner.variables[$Matches.role]
                if ($enabled) { $roleId }
            }
        }
    }

    It 'gives the Automation identity only Blob Data Contributor on its storage account' {
        $module = Get-CompiledRoleModule automationStorageRoles
        $module.condition | Should -Be "[equals(parameters('computeKind'), 'automation')]"
        $module.properties.mode | Should -Be 'Incremental'
        $module.properties.parameters.principalId.value | Should -Match "resourceId\('Microsoft.Resources/deployments', 'automation'\)"
        $module.properties.parameters.principalId.value | Should -Match '\.outputs\.identityPrincipalId\.value\]$'
        $module.properties.parameters.storageAccountName.value | Should -Match "resourceId\('Microsoft.Resources/deployments', 'storage'\)"
        $roles = @(Get-EnabledCompiledRoleIds $module)
        $roles.Count | Should -Be 1
        $roles[0] | Should -Be $contributor
        $module.properties.parameters.assignBlobOwner.value | Should -BeFalse
        $module.properties.parameters.assignBlobContributor.value | Should -BeTrue
        $module.properties.parameters.assignQueueContributor.value | Should -BeFalse
        $module.properties.parameters.assignTableContributor.value | Should -BeFalse
    }

    It 'preserves the separate Function identity and its existing role set' {
        $module = Get-CompiledRoleModule functionStorageRoles
        $module.condition | Should -Be "[equals(parameters('computeKind'), 'functionapp')]"
        $module.properties.parameters.principalId.value | Should -Match "resourceId\('Microsoft.Resources/deployments', 'functionApp'\)"
        $roles = @(Get-EnabledCompiledRoleIds $module | Sort-Object)
        $roles.Count | Should -Be 4
        $expected = @(
            'b7e6dc6d-f1e8-4753-8033-0f276bb0955b', $contributor,
            '974c5e8b-45b9-4653-ba55-5f855dd0fb88', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
        ) | Sort-Object
        ($roles -join ',') | Should -Be ($expected -join ',')
    }

    It 'preserves the optional deployer Contributor grant and exact principal binding' {
        $module = Get-CompiledRoleModule deployerStorageRoles
        $module.condition | Should -Be "[not(empty(parameters('deployerPrincipalId')))]"
        $module.properties.parameters.principalId.value | Should -Be "[parameters('deployerPrincipalId')]"
        $module.properties.parameters.principalType.value | Should -Be "[parameters('deployerPrincipalType')]"
        $roles = @(Get-EnabledCompiledRoleIds $module)
        $roles.Count | Should -Be 1
        $roles[0] | Should -Be $contributor
    }
}
