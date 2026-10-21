#Requires -Version 7.6
<#
.SYNOPSIS
Plans or executes one separately approved synthetic Automation job lifecycle.
.DESCRIPTION
Default mode is offline planning. Execute uses the maintained target guard and
supervised adapter. It does not provision, publish, upload, grant roles, validate
report semantics or clean up. Execute is not a substitute for action approval.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContextPath,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [switch]$Execute,
    [switch]$ReconcileOnly,
    [ValidateRange(1,3600)][int]$TimeoutSeconds=600,
    [ValidateRange(1,600)][int]$StopTimeoutSeconds=120,
    [ValidateRange(1,30)][int]$RequestTimeoutSeconds=20,
    [ValidateRange(1,30)][int]$PollSeconds=5,
    [ValidateRange(1,10)][int]$MaxReadErrors=3
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AutomationValidationAdapter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AutomationValidationPreflight.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AutomationJobLifecycle.psm1') -Force
$file=Get-Item -LiteralPath $ContextPath
if($file.Length -gt 131072 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid validation context file.'}
$text=Get-Content -LiteralPath $file.FullName -Raw
[AzdValidation.BoundedIO]::ValidateJsonObject($text)
$context=$text | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 32
Assert-ValidationContext $context | Out-Null
$jobId="/subscriptions/$($context.SubscriptionId)/resourceGroups/$($context.ResourceGroupName)/providers/Microsoft.Automation/automationAccounts/$($context.AutomationAccountName)/jobs/$($context.JobId)"
if(-not $Execute) {
    return [pscustomobject]@{
        mode='offline-plan';tenantId=$context.TenantId;expectedOperator=$context.ExpectedUserName
        jobResourceId=$jobId;runbook=$context.RunbookName;storageAccount=$context.StorageAccountName
        runbookSha256=$context.RunbookSha256;fixtureSha256=$context.FixtureSha256
        runtimeContractSha256=$context.RuntimeContractSha256
        selectedInputCount=$context.Artifacts.Count;selectedTemplateCount=$context.Templates.Count
        receiptPath=[IO.Path]::GetFullPath($ReceiptPath);reconcileOnly=[bool]$ReconcileOnly
        executionTimeoutSeconds=$TimeoutSeconds;stopTimeoutSeconds=$StopTimeoutSeconds
        permittedProtocol=$(if($ReconcileOnly){'same-job GET; bounded POST stop if unresolved'}else{'GET preflight; at most one exact-job PUT; same-job GET and bounded POST stop'})
        providerAccessPerformed=$false;cleanupAllowed=$false
        remaining='Requires explicit action approval; provisioned isolated cell, reviewed fixture/template/runbook identity, report acceptance and owned cleanup remain separate.'
    }
}
$adapter=New-AutomationValidationAdapter $context
$arguments=@{
    TenantId=$context.TenantId;SubscriptionId=$context.SubscriptionId;ResourceGroupName=$context.ResourceGroupName
    AutomationAccountName=$context.AutomationAccountName;RunbookName=$context.RunbookName;StorageAccountName=$context.StorageAccountName
    JobId=$context.JobId;FixtureSha256=$context.FixtureSha256;RunbookSha256=$context.RunbookSha256
    ReceiptPath=$ReceiptPath;TimeoutSeconds=$TimeoutSeconds;StopTimeoutSeconds=$StopTimeoutSeconds
    RequestTimeoutSeconds=$RequestTimeoutSeconds;PollSeconds=$PollSeconds;MaxReadErrors=$MaxReadErrors
    Request=$adapter.Request;Guard=$adapter.Guard;Preflight=$adapter.Preflight;ReconcileOnly=$ReconcileOnly
}
Invoke-ValidationJobLifecycle @arguments
