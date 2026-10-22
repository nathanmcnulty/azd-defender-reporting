#Requires -Version 7.6
# Synthetic cancellation fixture. No network, credentials or storage calls.
[CmdletBinding()]
param(
    [string]$StorageAccountName,
    [bool]$UseExistingExportsOnly,
    [bool]$IncludeAdvancedHunting,
    [bool]$UseDirectMergeDeviceLookup,
    [string]$DashboardDeliveryMode,
    [string]$Export
)
$ErrorActionPreference='Stop'
$expectedNames=@('StorageAccountName','UseExistingExportsOnly','IncludeAdvancedHunting','UseDirectMergeDeviceLookup','DashboardDeliveryMode','Export')
if(@($expectedNames|Where-Object {-not $PSBoundParameters.ContainsKey($_)}).Count -ne 0 -or
    $StorageAccountName -cnotmatch '\A[a-z0-9]{3,24}\z' -or
    -not $UseExistingExportsOnly -or $IncludeAdvancedHunting -or $UseDirectMergeDeviceLookup -or
    $DashboardDeliveryMode -cne 'SelfContained' -or $Export -cne 'BlobStorage'){
    throw 'Only the fixed synthetic validation parameters are accepted.'
}
Write-Output '{"synthetic":true,"phase":"waiting-for-bounded-cancellation"}'
Start-Sleep -Seconds 300
Write-Output '{"synthetic":true,"phase":"bounded-fallback-completed"}'
