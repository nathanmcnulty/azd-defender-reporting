BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/AutomationJobParameters.psm1') -Force
    $probe=Join-Path $PSScriptRoot 'fixtures/SyntheticCancellationProbe.ps1'
}
Describe 'Typed Automation job wire values' {
    It 'round-trips the outer request and each inner logical value with exact types' {
        $wire=Get-ValidationJobParameters -StorageAccountName syntheticstore -ParameterEncoding JsonValues
        $outer=@{properties=@{parameters=$wire}}|ConvertTo-Json -Depth 5 -Compress|ConvertFrom-Json -AsHashtable
        $outer.properties.parameters.Count|Should -Be 6
        $expected=@{StorageAccountName='syntheticstore';UseExistingExportsOnly=$true;IncludeAdvancedHunting=$false;UseDirectMergeDeviceLookup=$false;DashboardDeliveryMode='SelfContained';Export='BlobStorage'}
        foreach($key in $expected.Keys){
            $outer.properties.parameters[$key]|Should -BeOfType ([string])
            $logical=ConvertFrom-Json -InputObject $outer.properties.parameters[$key] -NoEnumerate
            $logical.GetType()|Should -Be $expected[$key].GetType()
            $logical|Should -BeExactly $expected[$key]
        }
        $wire.StorageAccountName|Should -BeExactly '"syntheticstore"'
        $wire.UseExistingExportsOnly|Should -BeExactly 'true'
    }
    It 'preserves the exact historical raw string serialization' {
        $wire=Get-ValidationJobParameters -StorageAccountName syntheticstore
        ($wire|ConvertTo-Json -Compress)|Should -BeExactly '{"StorageAccountName":"syntheticstore","UseExistingExportsOnly":"true","IncludeAdvancedHunting":"false","UseDirectMergeDeviceLookup":"false","DashboardDeliveryMode":"SelfContained","Export":"BlobStorage"}'
    }
    It 'rejects unrecognized or incorrectly cased encoding names' -ForEach @('jsonvalues','legacyraw','Other') {
        {Get-ValidationJobParameters -StorageAccountName syntheticstore -ParameterEncoding $_}|Should -Throw '*encoding*'
    }
}
Describe 'Typed cancellation fixture safety' {
    BeforeEach {
        $parameters=@{StorageAccountName='syntheticstore';UseExistingExportsOnly=$true;IncludeAdvancedHunting=$false;UseDirectMergeDeviceLookup=$false;DashboardDeliveryMode='SelfContained';Export='BlobStorage'}
        $state=@{sleeps=0}
        function Start-Sleep {param($Seconds) $state.sleeps++; throw 'Offline sleep tripwire reached'}
    }
    It 'accepts the typed wire round-trip then reaches the bounded wait' {
        $wire=Get-ValidationJobParameters -StorageAccountName syntheticstore -ParameterEncoding JsonValues
        foreach($key in @($parameters.Keys)){$parameters[$key]=ConvertFrom-Json -InputObject $wire[$key] -NoEnumerate}
        {& $probe @parameters}|Should -Throw '*sleep tripwire*'
        $state.sleeps|Should -Be 1
    }
    It 'rejects each missing parameter before waiting: <_>' -ForEach @('StorageAccountName','UseExistingExportsOnly','IncludeAdvancedHunting','UseDirectMergeDeviceLookup','DashboardDeliveryMode','Export') {
        $parameters.Remove($_)
        {& $probe @parameters}|Should -Throw '*fixed synthetic*'
        $state.sleeps|Should -Be 0
    }
    It 'rejects an unsafe flag before waiting: <_>' -ForEach @('UseExistingExportsOnly','IncludeAdvancedHunting','UseDirectMergeDeviceLookup') {
        $parameters[$_]=-not $parameters[$_]
        {& $probe @parameters}|Should -Throw '*fixed synthetic*'
        $state.sleeps|Should -Be 0
    }
}
