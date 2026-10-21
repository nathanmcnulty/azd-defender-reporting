BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/AutomationRuntimeContract.psm1') -Force
    $script:runtimeId='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/synthetic/providers/Microsoft.Automation/automationAccounts/aa/runtimeEnvironments/PowerShell-76-AzAccounts'
    function New-RuntimeReadback {
        $script:runtime=@{id=$script:runtimeId;properties=@{runtime=@{language='PowerShell';version='7.6'};defaultPackages=@{}}}
        $script:packages=@{value=@(@{id=$script:runtimeId+'/packages/Az.Accounts';name='Az.Accounts';properties=@{version='5.5.0';provisioningState='Succeeded';default=$false}})}
    }
}
Describe 'Locked Automation runtime and package metadata' {
    BeforeEach {New-RuntimeReadback}
    It 'builds a versioned and hash-bound package request without downloading or authenticating' {
        $contract=Get-AutomationRuntimeContract
        $link=Get-AutomationPackageContentLink
        $link.uri | Should -BeExactly 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/5.5.0'
        $link.version | Should -BeExactly '5.5.0'
        $link.contentHash.algorithm | Should -BeExactly 'sha256'
        $link.contentHash.value | Should -BeExactly '748a0abc2391b80385f25d41d740dc48d098cd2d6365bd70624fa165a4466044'
        $contract.Spec.package.sizeBytes | Should -Be 9999717
        $contract.Sha256 | Should -Match '^[a-f0-9]{64}$'
    }
    It 'rejects an unreviewed runtime contract: <_>' -ForEach @('UnknownKey','UnversionedUri','WrongHost','Hash','StringSize','Duplicate','NestedDuplicate','ArrayRoot','ArrayLanguage','ArrayVersion','ArrayName') {
        $case=$_
        $spec=(Get-AutomationRuntimeContract).Spec
        switch($case){
            'UnknownKey'{$spec.extra=$true}
            'UnversionedUri'{$spec.package.uri='https://www.powershellgallery.com/api/v2/package/Az.Accounts'}
            'WrongHost'{$spec.package.uri='https://example.invalid/Az.Accounts/5.5.0'}
            'Hash'{$spec.package.sha256='not-a-hash'}
            'StringSize'{$spec.package.sizeBytes='9999717'}
            'ArrayLanguage'{$spec.language=@('PowerShell')}
            'ArrayVersion'{$spec.version=@('7.6')}
            'ArrayName'{$spec.package.name=@('Az.Accounts')}
        }
        $json=$spec | ConvertTo-Json -Depth 10 -Compress
        if($case -eq 'Duplicate'){$json=$json.Replace('"schemaVersion":1','"schemaVersion":1,"SchemaVersion":1')}
        if($case -eq 'NestedDuplicate'){$json=$json.Replace('"name":"Az.Accounts"','"name":"Az.Accounts","Name":"Az.Accounts"')}
        if($case -eq 'ArrayRoot'){$json='['+$json+']'}
        $file=Join-Path $TestDrive 'invalid-runtime.json'
        Set-Content -LiteralPath $file -Value $json
        {Get-AutomationRuntimeContract -Path $file} | Should -Throw
    }
    It 'accepts complete exact metadata from both dictionary and PSCustomObject transports' {
        Assert-AutomationRuntimeReadback -RuntimeId $script:runtimeId -Runtime $script:runtime -Packages $script:packages | Should -BeTrue
        $runtimeObject=$script:runtime | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $packagesObject=$script:packages | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Assert-AutomationRuntimeReadback -RuntimeId $script:runtimeId -Runtime $runtimeObject -Packages $packagesObject | Should -BeTrue
    }
    It 'rejects incomplete or drifted runtime metadata: <_>' -ForEach @('WrongScope','Language','Version','ArrayLanguage','DefaultPackage','ExtraPackage','Paged','NumericNextLink','WrongModule','WrongVersion','Created','Failed','DefaultFlag') {
        switch($_){
            'WrongScope'{$script:runtime.id=$script:runtimeId.Replace('/synthetic/','/foreign/')}
            'Language'{$script:runtime.properties.runtime.language='Python'}
            'Version'{$script:runtime.properties.runtime.version='7.4'}
            'ArrayLanguage'{$script:runtime.properties.runtime.language=@('PowerShell')}
            'DefaultPackage'{$script:runtime.properties.defaultPackages.Az='latest'}
            'ExtraPackage'{$script:packages.value+=@{name='unexpected'}}
            'Paged'{$script:packages.nextLink='https://management.azure.com/more'}
            'NumericNextLink'{$script:packages.nextLink=0}
            'WrongModule'{$script:packages.value[0].name='Az'}
            'WrongVersion'{$script:packages.value[0].properties.version='5.3.4'}
            'Created'{$script:packages.value[0].properties.provisioningState='Created'}
            'Failed'{$script:packages.value[0].properties.provisioningState='Failed'}
            'DefaultFlag'{$script:packages.value[0].properties.default='false'}
        }
        {Assert-AutomationRuntimeReadback -RuntimeId $script:runtimeId -Runtime $script:runtime -Packages $script:packages} | Should -Throw
    }
}
