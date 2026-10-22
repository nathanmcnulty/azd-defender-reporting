#Requires -Version 7.6
Set-StrictMode -Version Latest

function Get-ValidationParameterTypes {
    [ordered]@{StorageAccountName='System.String';UseExistingExportsOnly='System.Boolean';IncludeAdvancedHunting='System.Boolean';UseDirectMergeDeviceLookup='System.Boolean';DashboardDeliveryMode='System.String';Export='System.String'}
}

function Get-ValidationJobParameters {
    <#.SYNOPSIS
    Returns exact Automation wire strings, including the historical receipt format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('\A[a-z0-9]{3,24}\z')][string]$StorageAccountName,
        [string]$ParameterEncoding='LegacyRaw'
    )
    if($ParameterEncoding -cnotin @('LegacyRaw','JsonValues')){throw 'Unsupported parameter encoding.'}
    $values=[ordered]@{StorageAccountName=$StorageAccountName;UseExistingExportsOnly=$true;IncludeAdvancedHunting=$false;UseDirectMergeDeviceLookup=$false;DashboardDeliveryMode='SelfContained';Export='BlobStorage'}
    $wire=[ordered]@{}
    foreach($key in $values.Keys){
        if($ParameterEncoding -ceq 'JsonValues'){
            # Az.Automation serializes EACH logical value before the outer body.
            $wire[$key]=ConvertTo-Json -InputObject $values[$key] -Compress
        } elseif($values[$key] -is [bool]){
            $wire[$key]=$values[$key].ToString().ToLowerInvariant()
        } else {$wire[$key]=$values[$key]}
    }
    return $wire
}
Export-ModuleMember -Function Get-ValidationJobParameters,Get-ValidationParameterTypes
