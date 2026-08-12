#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ResourceGroupName = $env:AZURE_RESOURCE_GROUP,
    [string]$FunctionAppName,
    [string]$AutomationAccountName,
    [string]$ContainerAppName,
    [string]$StorageAccountName,
    [string]$SecurityGroup = $env:HOSTED_AUTH_SECURITY_GROUP,
    [string]$AppRegistrationDisplayName = $env:HOSTED_AUTH_APP_DISPLAY_NAME,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [switch]$PlanOnly,
    [switch]$SkipAuthSetup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

function Resolve-ResourceGroupName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Mode,
        [string]$RequestedResourceGroupName,
        [string]$RequestedFunctionAppName,
        [string]$RequestedAutomationAccountName,
        [string]$RequestedContainerAppName
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedResourceGroupName)) {
        return $RequestedResourceGroupName
    }

    $environmentResourceGroup = Get-EnvironmentValue -Name 'AZURE_RESOURCE_GROUP'
    if (-not [string]::IsNullOrWhiteSpace($environmentResourceGroup)) {
        return $environmentResourceGroup
    }

    if ($Mode.RequiresFunctionAppPublish -and -not [string]::IsNullOrWhiteSpace($RequestedFunctionAppName)) {
        return Resolve-ResourceGroupNameFromResource -ResourceName $RequestedFunctionAppName -ResourceType 'Microsoft.Web/sites'
    }

    if ($Mode.RequiresAutomationPublish -and -not [string]::IsNullOrWhiteSpace($RequestedAutomationAccountName)) {
        return Resolve-ResourceGroupNameFromResource -ResourceName $RequestedAutomationAccountName -ResourceType 'Microsoft.Automation/automationAccounts'
    }

    if ($Mode.RequiresHostedSurface -and -not [string]::IsNullOrWhiteSpace($RequestedContainerAppName)) {
        return Resolve-ResourceGroupNameFromResource -ResourceName $RequestedContainerAppName -ResourceType 'Microsoft.App/containerApps'
    }

    throw 'ResourceGroupName could not be resolved. Pass -ResourceGroupName explicitly or select an azd environment that defines AZURE_RESOURCE_GROUP.'
}

function Resolve-ComputeResourceNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Mode,
        [Parameter(Mandatory = $true)]
        [string]$ResolvedResourceGroupName,
        [string]$RequestedFunctionAppName,
        [string]$RequestedAutomationAccountName,
        [string]$RequestedContainerAppName
    )

    return [PSCustomObject]@{
        FunctionAppName = if ($Mode.RequiresFunctionAppPublish) {
            if (-not [string]::IsNullOrWhiteSpace($RequestedFunctionAppName)) {
                $RequestedFunctionAppName
            }
            else {
                Resolve-SingleResourceNameInGroup -ResourceGroupName $ResolvedResourceGroupName -ResourceType 'Microsoft.Web/sites' -FriendlyName 'Function App'
            }
        }
        else { '' }
        AutomationAccountName = if ($Mode.RequiresAutomationPublish) {
            if (-not [string]::IsNullOrWhiteSpace($RequestedAutomationAccountName)) {
                $RequestedAutomationAccountName
            }
            else {
                Resolve-SingleResourceNameInGroup -ResourceGroupName $ResolvedResourceGroupName -ResourceType 'Microsoft.Automation/automationAccounts' -FriendlyName 'Automation Account'
            }
        }
        else { '' }
        ContainerAppName = if ($Mode.RequiresHostedSurface) {
            if (-not [string]::IsNullOrWhiteSpace($RequestedContainerAppName)) {
                $RequestedContainerAppName
            }
            else {
                Resolve-SingleResourceNameInGroup -ResourceGroupName $ResolvedResourceGroupName -ResourceType 'Microsoft.App/containerApps' -FriendlyName 'Container App'
            }
        }
        else { '' }
    }
}

& (Join-Path $PSScriptRoot 'Validate-Environment.ps1') -ApplyDefaults -PersistAzdEnv -CommandName 'publish-deployment' | Out-Null

$ResourceGroupName = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { Get-EnvironmentValue -Name 'AZURE_RESOURCE_GROUP' } else { $ResourceGroupName }
$SecurityGroup = if ([string]::IsNullOrWhiteSpace($SecurityGroup)) { Get-EnvironmentValue -Name 'HOSTED_AUTH_SECURITY_GROUP' } else { $SecurityGroup }
$AppRegistrationDisplayName = if ([string]::IsNullOrWhiteSpace($AppRegistrationDisplayName)) { Get-EnvironmentValue -Name 'HOSTED_AUTH_APP_DISPLAY_NAME' } else { $AppRegistrationDisplayName }
$RepositoryPath = if ([string]::IsNullOrWhiteSpace($RepositoryPath)) { Get-EnvironmentValue -Name 'DEFENDER_REPORTING_PATH' } else { $RepositoryPath }
$RepositoryUrl = if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) { Get-EnvironmentValue -Name 'DEFENDER_REPORTING_REPO' } else { $RepositoryUrl }
$Ref = if ([string]::IsNullOrWhiteSpace($Ref)) { Get-EnvironmentValue -Name 'DEFENDER_REPORTING_REF' } else { $Ref }

$mode = & (Join-Path $PSScriptRoot 'Get-DeploymentMode.ps1')
$resolvedSkipAuthSetup = if ($PSBoundParameters.ContainsKey('SkipAuthSetup')) {
    [bool]$SkipAuthSetup
}
else {
    Resolve-BooleanString -Value (Get-EnvironmentValue -Name 'SKIP_HOSTED_AUTH_SETUP') -Default $false
}

$resolvedResourceGroupName = Resolve-ResourceGroupName `
    -Mode $mode `
    -RequestedResourceGroupName $ResourceGroupName `
    -RequestedFunctionAppName $FunctionAppName `
    -RequestedAutomationAccountName $AutomationAccountName `
    -RequestedContainerAppName $ContainerAppName

$resolvedNames = Resolve-ComputeResourceNames `
    -Mode $mode `
    -ResolvedResourceGroupName $resolvedResourceGroupName `
    -RequestedFunctionAppName $FunctionAppName `
    -RequestedAutomationAccountName $AutomationAccountName `
    -RequestedContainerAppName $ContainerAppName

$requiresTemplatePublish = ($mode.RequiresFunctionAppPublish -or $mode.RequiresAutomationPublish -or $mode.RequiresHostedSurface)
$resolvedStorageAccountName = if ($requiresTemplatePublish) {
    Resolve-StorageAccountName -ResourceGroupName $resolvedResourceGroupName -RequestedStorageAccountName $StorageAccountName
}
else {
    ''
}

$result = [PSCustomObject]@{
    ResourceGroupName = $resolvedResourceGroupName
    StorageAccountName = $resolvedStorageAccountName
    ComputeKind = $mode.ComputeKind
    WebKind = $mode.WebKind
    EffectivePackageMode = $mode.EffectivePackageMode
    FunctionAppName = [string]$resolvedNames.FunctionAppName
    AutomationAccountName = [string]$resolvedNames.AutomationAccountName
    ContainerAppName = [string]$resolvedNames.ContainerAppName
    SkipAuthSetup = $resolvedSkipAuthSetup
}

if ($PlanOnly) {
    $result | Add-Member -NotePropertyName Operations -NotePropertyValue @(
        if ($requiresTemplatePublish) { 'Publish template assets' }
        if ($mode.RequiresFunctionAppPublish) { 'Publish Function App package' }
        if ($mode.RequiresAutomationPublish) { 'Publish Automation runbook' }
        if ($mode.RequiresHostedSurface) { 'Publish hosted surface and configure auth' }
    )

    if ($mode.RequiresHostedSurface) {
        $hostedPlan = & (Join-Path $PSScriptRoot 'Publish-HostedSurface.ps1') `
            -ResourceGroupName $resolvedResourceGroupName `
            -ContainerAppName ([string]$resolvedNames.ContainerAppName) `
            -StorageAccountName $resolvedStorageAccountName `
            -SecurityGroup $SecurityGroup `
            -AppRegistrationDisplayName $AppRegistrationDisplayName `
            -RepositoryPath $RepositoryPath `
            -RepositoryUrl $RepositoryUrl `
            -Ref $Ref `
            -PlanOnly `
            -SkipAuthSetup:$resolvedSkipAuthSetup `
            -SkipTemplatePublish

        $result | Add-Member -NotePropertyName HostedSurfacePlan -NotePropertyValue $hostedPlan
    }

    $result
    return
}

$templatePublishResult = if ($requiresTemplatePublish) {
    @(& (Join-Path $PSScriptRoot 'Publish-TemplateAssets.ps1') `
        -StorageAccountName $resolvedStorageAccountName `
        -RepositoryPath $RepositoryPath `
        -RepositoryUrl $RepositoryUrl `
        -Ref $Ref) | Where-Object {
            $_ -is [psobject] -and $_.PSObject.Properties.Match('ContainerName').Count -gt 0
        } | Select-Object -Last 1
}
else {
    $null
}

if ($requiresTemplatePublish -and $null -eq $templatePublishResult) {
    throw 'Publish-TemplateAssets.ps1 did not return the expected template publish result.'
}

$result | Add-Member -NotePropertyName TemplatePublish -NotePropertyValue $templatePublishResult

if ($mode.RequiresFunctionAppPublish) {
    $functionPublishResult = & (Join-Path $PSScriptRoot 'Publish-FunctionAppPackage.ps1') `
        -ResourceGroupName $resolvedResourceGroupName `
        -FunctionAppName ([string]$resolvedNames.FunctionAppName) `
        -RepositoryPath $RepositoryPath `
        -RepositoryUrl $RepositoryUrl `
        -Ref $Ref `
        -SkipTemplatePublish

    $result | Add-Member -NotePropertyName FunctionAppPublish -NotePropertyValue $functionPublishResult
}

if ($mode.RequiresAutomationPublish) {
    $automationPublishResult = & (Join-Path $PSScriptRoot 'Publish-AutomationRunbook.ps1') `
        -ResourceGroupName $resolvedResourceGroupName `
        -AutomationAccountName ([string]$resolvedNames.AutomationAccountName) `
        -StorageAccountName $resolvedStorageAccountName `
        -RepositoryPath $RepositoryPath `
        -RepositoryUrl $RepositoryUrl `
        -Ref $Ref `
        -SkipTemplatePublish

    $result | Add-Member -NotePropertyName AutomationPublish -NotePropertyValue $automationPublishResult
}

if ($mode.RequiresHostedSurface) {
    $hostedPublishResult = & (Join-Path $PSScriptRoot 'Publish-HostedSurface.ps1') `
        -ResourceGroupName $resolvedResourceGroupName `
        -ContainerAppName ([string]$resolvedNames.ContainerAppName) `
        -StorageAccountName $resolvedStorageAccountName `
        -SecurityGroup $SecurityGroup `
        -AppRegistrationDisplayName $AppRegistrationDisplayName `
        -RepositoryPath $RepositoryPath `
        -RepositoryUrl $RepositoryUrl `
        -Ref $Ref `
        -SkipAuthSetup:$resolvedSkipAuthSetup `
        -SkipTemplatePublish

    $result | Add-Member -NotePropertyName HostedSurfacePublish -NotePropertyValue $hostedPublishResult
}

$result
