#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory = $true)]
    [string]$ContainerAppName,
    [string]$SecurityGroup = '',
    [string]$AppRegistrationDisplayName = '',
    [switch]$SkipAuthSetup,
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

$containerAppApiVersion = '2024-03-01'
$graphApiBaseUrl = 'https://graph.microsoft.com'
$msGraphResourceAppId = '00000003-0000-0000-c000-000000000000'
$delegatedPermissions = @(
    @{ id = '37f7f235-527c-4136-accd-4a02d197296e'; type = 'Scope' }
    @{ id = '64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0'; type = 'Scope' }
    @{ id = '14dad69e-099b-42c9-810b-d002981feec1'; type = 'Scope' }
)
$zeroGuid = '00000000-0000-0000-0000-000000000000'

function Escape-ODataStringLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function Join-QueryParameter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return '{0}={1}' -f $Name, [System.Uri]::EscapeDataString($Value)
}

function Resolve-SecurityGroupDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Group
    )

    $parsedGuid = [guid]::Empty
    if ([guid]::TryParse($Group, [ref]$parsedGuid)) {
        $groupResult = Get-AzCliJson -Arguments @(
            'ad', 'group', 'show',
            '--group', $Group,
            '--query', '{id:id,displayName:displayName}',
            '--output', 'json'
        )

        return [PSCustomObject]@{
            Id = [string]$groupResult.id
            DisplayName = [string]$groupResult.displayName
        }
    }

    $groupMatches = @(
        Get-AzCliJson -Arguments @(
            'ad', 'group', 'list',
            '--display-name', $Group,
            '--query', '[].{id:id,displayName:displayName}',
            '--output', 'json'
        )
    )

    if ($groupMatches.Count -eq 0) {
        throw "No Entra ID group found with display name '$Group'. Pass the group object ID or a unique display name, or opt out with -SkipAuthSetup."
    }

    if ($groupMatches.Count -gt 1) {
        $groupSummary = $groupMatches | ForEach-Object { '{0} ({1})' -f $_.displayName, $_.id }
        throw "Multiple Entra ID groups matched '$Group': $($groupSummary -join ', '). Pass the group object ID explicitly."
    }

    return [PSCustomObject]@{
        Id = [string]$groupMatches[0].id
        DisplayName = [string]$groupMatches[0].displayName
    }
}

function Resolve-AppRegistrationDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,
        [string]$RequestedDisplayName
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedDisplayName)) {
        return $RequestedDisplayName
    }

    $environmentName = Get-EnvironmentValue -Name 'AZURE_ENV_NAME'
    if (-not [string]::IsNullOrWhiteSpace($environmentName)) {
        return "Defender Reporting Dashboard ($environmentName)"
    }

    return "Defender Reporting Dashboard ($ContainerAppName)"
}

function Resolve-ExistingApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$RedirectUri
    )

    $escapedName = Escape-ODataStringLiteral -Value $DisplayName
    $queryUrl = '{0}/v1.0/applications?{1}&{2}' -f `
        $graphApiBaseUrl, `
        (Join-QueryParameter -Name '$filter' -Value ("displayName eq '$escapedName'")), `
        (Join-QueryParameter -Name '$select' -Value 'id,appId,displayName,web,requiredResourceAccess')

    $applicationsResponse = Invoke-AzRestJson -Method GET -Url $queryUrl
    $existingApps = @($applicationsResponse.value)
    $redirectMatchedApps = @($existingApps | Where-Object { @($_.web.redirectUris) -contains $RedirectUri })

    if ($redirectMatchedApps.Count -gt 1) {
        $candidateAppIds = ($redirectMatchedApps | ForEach-Object { $_.appId }) -join ', '
        throw "Multiple Entra app registrations named '$DisplayName' already include redirect URI '$RedirectUri': $candidateAppIds. Clean up duplicates or pass -AppRegistrationDisplayName explicitly."
    }

    if ($redirectMatchedApps.Count -eq 1) {
        return $redirectMatchedApps[0]
    }

    if ($existingApps.Count -gt 1) {
        $candidateAppIds = ($existingApps | ForEach-Object { $_.appId }) -join ', '
        throw "Multiple Entra app registrations named '$DisplayName' were found: $candidateAppIds. Clean up duplicates or pass -AppRegistrationDisplayName explicitly."
    }

    if ($existingApps.Count -eq 1) {
        return $existingApps[0]
    }

    return $null
}

function Ensure-ApplicationRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$RedirectUri
    )

    $existingApplication = Resolve-ExistingApplication -DisplayName $DisplayName -RedirectUri $RedirectUri
    $existingRedirectUris = @()
    if ($null -ne $existingApplication -and $null -ne $existingApplication.web) {
        $existingRedirectUris = @($existingApplication.web.redirectUris)
    }

    $appBody = @{
        displayName = $DisplayName
        signInAudience = 'AzureADMyOrg'
        web = @{
            redirectUris = @(
                @($existingRedirectUris) + $RedirectUri |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    Select-Object -Unique
            )
            implicitGrantSettings = @{
                enableIdTokenIssuance = $true
            }
        }
        requiredResourceAccess = @(
            @{
                resourceAppId = $msGraphResourceAppId
                resourceAccess = $delegatedPermissions
            }
        )
    } | ConvertTo-Json -Depth 8

    if ($null -eq $existingApplication) {
        return Invoke-AzRestJson -Method POST -Url "$graphApiBaseUrl/v1.0/applications" -Body $appBody
    }

    Invoke-AzRestJson -Method PATCH -Url "$graphApiBaseUrl/v1.0/applications/$($existingApplication.id)" -Body $appBody | Out-Null
    return Invoke-AzRestJson -Method GET -Url "$graphApiBaseUrl/v1.0/applications/$($existingApplication.id)"
}

function Ensure-ServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppClientId
    )

    $queryUrl = '{0}/v1.0/servicePrincipals?{1}&{2}' -f `
        $graphApiBaseUrl, `
        (Join-QueryParameter -Name '$filter' -Value ("appId eq '$AppClientId'")), `
        (Join-QueryParameter -Name '$select' -Value 'id,appId,appRoleAssignmentRequired')
    $servicePrincipalResponse = Invoke-AzRestJson -Method GET -Url $queryUrl
    $servicePrincipals = @($servicePrincipalResponse.value)

    if ($servicePrincipals.Count -gt 1) {
        $candidateSpIds = ($servicePrincipals | ForEach-Object { $_.id }) -join ', '
        throw "Multiple service principals were found for appId '$AppClientId': $candidateSpIds."
    }

    if ($servicePrincipals.Count -eq 1) {
        return $servicePrincipals[0]
    }

    return Invoke-AzRestJson -Method POST -Url "$graphApiBaseUrl/v1.0/servicePrincipals" -Body (@{ appId = $AppClientId } | ConvertTo-Json)
}

function Ensure-DelegatedPermissionGrant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalObjectId,
        [Parameter(Mandatory = $true)]
        [string]$AppClientId
    )

    $msGraphSpQueryUrl = '{0}/v1.0/servicePrincipals?{1}&{2}' -f `
        $graphApiBaseUrl, `
        (Join-QueryParameter -Name '$filter' -Value ("appId eq '$msGraphResourceAppId'")), `
        (Join-QueryParameter -Name '$select' -Value 'id')
    $msGraphServicePrincipal = Invoke-AzRestJson -Method GET -Url $msGraphSpQueryUrl
    $msGraphServicePrincipalId = [string]$msGraphServicePrincipal.value[0].id

    $grantQueryUrl = '{0}/v1.0/oauth2PermissionGrants?{1}&{2}' -f `
        $graphApiBaseUrl, `
        (Join-QueryParameter -Name '$filter' -Value ("clientId eq '$ServicePrincipalObjectId' and resourceId eq '$msGraphServicePrincipalId'")), `
        (Join-QueryParameter -Name '$select' -Value 'id,scope')
    $existingGrants = @((Invoke-AzRestJson -Method GET -Url $grantQueryUrl).value)
    if ($existingGrants.Count -gt 0) {
        return
    }

    $grantBody = @{
        clientId = $ServicePrincipalObjectId
        consentType = 'AllPrincipals'
        principalId = $null
        resourceId = $msGraphServicePrincipalId
        scope = 'openid email profile'
    } | ConvertTo-Json

    try {
        Invoke-AzRestJson -Method POST -Url "$graphApiBaseUrl/v1.0/oauth2PermissionGrants" -Body $grantBody | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'already exists') {
            return
        }

        $tenantId = [string](Get-AzCliJson -Arguments @('account', 'show', '--query', 'tenantId', '--output', 'json'))
        $consentUrl = "https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$AppClientId"
        throw "Granting admin consent for openid/email/profile failed. An administrator may need to approve the app first: $consentUrl`n$($_.Exception.Message)"
    }
}

function Ensure-ServicePrincipalAssignmentRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalObjectId,
        [Parameter(Mandatory = $true)]
        [bool]$Required
    )

    $patchBody = @{ appRoleAssignmentRequired = $Required } | ConvertTo-Json
    Invoke-AzRestJson -Method PATCH -Url "$graphApiBaseUrl/v1.0/servicePrincipals/$ServicePrincipalObjectId" -Body $patchBody | Out-Null
}

function Ensure-SecurityGroupAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalObjectId,
        [Parameter(Mandatory = $true)]
        [string]$SecurityGroupId
    )

    $assignmentQueryUrl = '{0}/v1.0/servicePrincipals/{1}/appRoleAssignedTo?{2}' -f `
        $graphApiBaseUrl, `
        $ServicePrincipalObjectId, `
        (Join-QueryParameter -Name '$select' -Value 'id,principalId')
    $existingAssignments = @(@((Invoke-AzRestJson -Method GET -Url $assignmentQueryUrl).value) | Where-Object {
        [string]$_.principalId -eq $SecurityGroupId
    })
    if ($existingAssignments.Count -gt 0) {
        return
    }

    $assignmentBody = @{
        principalId = $SecurityGroupId
        resourceId = $ServicePrincipalObjectId
        appRoleId = $zeroGuid
    } | ConvertTo-Json

    try {
        Invoke-AzRestJson -Method POST -Url "$graphApiBaseUrl/v1.0/servicePrincipals/$ServicePrincipalObjectId/appRoleAssignments" -Body $assignmentBody | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'already exists|EntitlementGrant entry already exists|Permission being assigned already exists') {
            return
        }

        throw
    }
}

function Get-CurrentAuthState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AuthConfigUrl
    )

    $authConfig = Invoke-AzRestJson -Method GET -Url $AuthConfigUrl -AllowNotFound
    $authEnabled = $false
    $clientId = ''
    if ($null -ne $authConfig -and $null -ne $authConfig.properties) {
        $authEnabled = [bool]($authConfig.properties.platform.enabled)
        if ($null -ne $authConfig.properties.identityProviders -and $null -ne $authConfig.properties.identityProviders.azureActiveDirectory) {
            $clientId = [string]$authConfig.properties.identityProviders.azureActiveDirectory.registration.clientId
        }
    }

    return [PSCustomObject]@{
        Enabled = $authEnabled
        ClientId = $clientId
        Raw = $authConfig
    }
}

if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required for hosted auth configuration.'
}

$resolvedSkipAuthSetup = if ($PSBoundParameters.ContainsKey('SkipAuthSetup')) {
    [bool]$SkipAuthSetup
}
else {
    Resolve-BooleanString -Value (Get-EnvironmentValue -Name 'SKIP_HOSTED_AUTH_SETUP') -Default $false
}

$resolvedSecurityGroup = if ([string]::IsNullOrWhiteSpace($SecurityGroup)) {
    Get-EnvironmentValue -Name 'HOSTED_AUTH_SECURITY_GROUP'
}
else {
    $SecurityGroup
}

$requestedAppRegistrationDisplayName = if ([string]::IsNullOrWhiteSpace($AppRegistrationDisplayName)) {
    Get-EnvironmentValue -Name 'HOSTED_AUTH_APP_DISPLAY_NAME'
}
else {
    $AppRegistrationDisplayName
}

$resolvedAppRegistrationDisplayName = Resolve-AppRegistrationDisplayName `
    -ContainerAppName $ContainerAppName `
    -RequestedDisplayName $requestedAppRegistrationDisplayName

$account = Get-AzCliJson -Arguments @('account', 'show', '--output', 'json')
$subscriptionId = [string]$account.id
$tenantId = [string]$account.tenantId

$containerApp = Get-AzCliJson -Arguments @(
    'resource', 'show',
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.App/containerApps',
    '--name', $ContainerAppName,
    '--query', '{fqdn:properties.configuration.ingress.fqdn}',
    '--output', 'json'
)

if ($null -eq $containerApp -or [string]::IsNullOrWhiteSpace([string]$containerApp.fqdn)) {
    throw "Container App '$ContainerAppName' was not found in resource group '$ResourceGroupName' or does not expose an ingress FQDN."
}

$containerAppUrl = 'https://{0}' -f ([string]$containerApp.fqdn)
$redirectUri = '{0}/.auth/login/aad/callback' -f $containerAppUrl
$authConfigUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/$ContainerAppName/authConfigs/current?api-version=$containerAppApiVersion"
$currentAuthState = Get-CurrentAuthState -AuthConfigUrl $authConfigUrl

$result = [PSCustomObject]@{
    ResourceGroupName = $ResourceGroupName
    ContainerAppName = $ContainerAppName
    ContainerAppUrl = $containerAppUrl
    SkipAuthSetup = $resolvedSkipAuthSetup
    CurrentAuthEnabled = $currentAuthState.Enabled
    AppRegistrationDisplayName = $resolvedAppRegistrationDisplayName
    RedirectUri = $redirectUri
    SecurityGroup = if ([string]::IsNullOrWhiteSpace($resolvedSecurityGroup)) { '' } else { $resolvedSecurityGroup }
    SecurityGroupId = ''
    SecurityGroupDisplayName = ''
    AuthAccessScope = if ($resolvedSkipAuthSetup) { 'ExistingConfiguration' } elseif ([string]::IsNullOrWhiteSpace($resolvedSecurityGroup)) { 'TenantWide' } else { 'SecurityGroupRestricted' }
    AppRegistrationClientId = if ([string]::IsNullOrWhiteSpace($currentAuthState.ClientId)) { '' } else { $currentAuthState.ClientId }
    AuthManagementMode = if ($resolvedSkipAuthSetup) { 'Skipped' } else { 'Managed' }
    ValidationExpectation = if ($resolvedSkipAuthSetup) {
        if ($currentAuthState.Enabled) { 'CurrentAuthState' } else { 'Anonymous200' }
    }
    else {
        'RedirectOrAuthChallenge'
    }
    ReadyToApply = $true
}

if ($resolvedSkipAuthSetup) {
    $result
    return
}

if ([string]::IsNullOrWhiteSpace($resolvedSecurityGroup)) {
    Write-Warning 'HOSTED_AUTH_SECURITY_GROUP was not provided. Hosted Easy Auth will be configured for tenant-wide authenticated-user access instead of security-group restriction.'

    if ($PlanOnly) {
        $result
        return
    }
}

$securityGroupDefinition = $null
if (-not [string]::IsNullOrWhiteSpace($resolvedSecurityGroup)) {
    $securityGroupDefinition = Resolve-SecurityGroupDefinition -Group $resolvedSecurityGroup
    $result.SecurityGroupId = $securityGroupDefinition.Id
    $result.SecurityGroupDisplayName = $securityGroupDefinition.DisplayName
}

if ($PlanOnly) {
    $result
    return
}

$application = Ensure-ApplicationRegistration -DisplayName $resolvedAppRegistrationDisplayName -RedirectUri $redirectUri
$servicePrincipal = Ensure-ServicePrincipal -AppClientId ([string]$application.appId)
Ensure-DelegatedPermissionGrant -ServicePrincipalObjectId ([string]$servicePrincipal.id) -AppClientId ([string]$application.appId)
Ensure-ServicePrincipalAssignmentRequirement -ServicePrincipalObjectId ([string]$servicePrincipal.id) -Required ($null -ne $securityGroupDefinition)
if ($null -ne $securityGroupDefinition) {
    Ensure-SecurityGroupAssignment -ServicePrincipalObjectId ([string]$servicePrincipal.id) -SecurityGroupId $securityGroupDefinition.Id
}

$authConfigPayload = @{
    properties = @{
        platform = @{
            enabled = $true
        }
        globalValidation = @{
            unauthenticatedClientAction = 'RedirectToLoginPage'
        }
        identityProviders = @{
            azureActiveDirectory = @{
                registration = @{
                    openIdIssuer = "https://login.microsoftonline.com/$tenantId/v2.0"
                    clientId = [string]$application.appId
                }
                validation = @{
                    allowedAudiences = @([string]$application.appId)
                }
            }
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-AzRestJson -Method PUT -Url $authConfigUrl -Body $authConfigPayload | Out-Null

$result.AppRegistrationClientId = [string]$application.appId
$result.CurrentAuthEnabled = $true
$result
