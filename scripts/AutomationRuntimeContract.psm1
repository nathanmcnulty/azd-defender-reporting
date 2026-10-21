#Requires -Version 7.6
Set-StrictMode -Version Latest

function Get-AutomationRuntimeContract {
    <#.SYNOPSIS
    Reads the reviewed runtime/package identity without authentication or downloads.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path=(Join-Path (Split-Path $PSScriptRoot -Parent) 'contracts/automation-runtime.json'))
    $ErrorActionPreference='Stop'
    $file=Get-Item -LiteralPath $Path
    if($file.PSIsContainer -or $file.Length -gt 4096 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid runtime contract file.'}
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xfeff)
    $document=[Text.Json.JsonDocument]::Parse($text)
    try {
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'Invalid runtime contract root.'}
        foreach($element in @($document.RootElement,$document.RootElement.GetProperty('package'))) {
            if($element.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'Invalid runtime package object.'}
            $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($property in $element.EnumerateObject()){if(-not $names.Add($property.Name)){throw 'Duplicate runtime contract property.'}}
        }
    } finally {$document.Dispose()}
    $spec=$text | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 8
    $keys=@('schemaVersion','runtimeEnvironmentName','language','version','package')
    $packageKeys=@('name','version','uri','sha256','sizeBytes')
    if($spec.Count -ne $keys.Count -or @($spec.Keys | Where-Object {$_ -cnotin $keys}).Count -or
        $spec.schemaVersion -isnot [long] -or $spec.schemaVersion -ne 1 -or
        $spec.runtimeEnvironmentName -isnot [string] -or $spec.runtimeEnvironmentName -cnotmatch '\A[a-zA-Z][a-zA-Z0-9_-]{0,62}\z' -or
        $spec.language -isnot [string] -or $spec.language -cne 'PowerShell' -or $spec.version -isnot [string] -or $spec.version -cne '7.6' -or
        $spec.package -isnot [Collections.IDictionary] -or $spec.package.Count -ne $packageKeys.Count -or
        @($spec.package.Keys | Where-Object {$_ -cnotin $packageKeys}).Count){throw 'Invalid runtime contract shape.'}
    $package=$spec.package
    if($package.name -isnot [string] -or $package.name -cne 'Az.Accounts' -or $package.version -isnot [string] -or $package.version -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z' -or
        $package.uri -isnot [string] -or $package.uri -cne "https://www.powershellgallery.com/api/v2/package/Az.Accounts/$($package.version)" -or
        $package.sha256 -isnot [string] -or $package.sha256 -cnotmatch '\A[a-f0-9]{64}\z' -or
        $package.sizeBytes -isnot [long] -or $package.sizeBytes -lt 1 -or $package.sizeBytes -gt 32MB){throw 'Invalid runtime package identity.'}
    return @{Spec=$spec;Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
}

function Get-AutomationPackageContentLink {
    <#.SYNOPSIS
    Builds the exact versioned, hash-bound package import request from its contract.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $package=(Get-AutomationRuntimeContract).Spec.package
    return @{uri=$package.uri;version=$package.version;contentHash=@{algorithm='sha256';value=$package.sha256}}
}

function Assert-AutomationRuntimeReadback {
    <#.SYNOPSIS
    Checks runtime metadata and a complete exact-package inventory; does not measure remote bytes.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)]$Runtime,[Parameter(Mandatory)]$Packages)
    $spec=(Get-AutomationRuntimeContract).Spec
    # The publisher reads PSCustomObject; supervised preflight reads dictionaries.
    $runtimeData=$Runtime | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json -AsHashtable -NoEnumerate
    $packageData=$Packages | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json -AsHashtable -NoEnumerate
    if($runtimeData -isnot [Collections.IDictionary] -or $runtimeData.id -isnot [string] -or $runtimeData.id -ine $RuntimeId -or
        $runtimeData.properties -isnot [Collections.IDictionary] -or $runtimeData.properties.runtime -isnot [Collections.IDictionary] -or
        $runtimeData.properties.runtime.language -isnot [string] -or $runtimeData.properties.runtime.language -cne $spec.language -or
        $runtimeData.properties.runtime.version -isnot [string] -or $runtimeData.properties.runtime.version -cne $spec.version -or
        $runtimeData.properties.defaultPackages -isnot [Collections.IDictionary] -or $runtimeData.properties.defaultPackages.Count -ne 0){throw 'Runtime metadata does not match the locked environment.'}
    if($packageData -isnot [Collections.IDictionary] -or $packageData.value -isnot [array] -or $packageData.value.Count -ne 1 -or
        ($packageData.Contains('nextLink') -and $null -ne $packageData.nextLink -and ($packageData.nextLink -isnot [string] -or $packageData.nextLink -cne ''))){throw 'Runtime package inventory is incomplete or unexpected.'}
    $package=$packageData.value[0]
    if($package -isnot [Collections.IDictionary] -or $package.id -isnot [string] -or $package.id -ine "$RuntimeId/packages/$($spec.package.name)" -or
        $package.name -isnot [string] -or $package.name -cne $spec.package.name -or $package.properties -isnot [Collections.IDictionary] -or
        $package.properties.version -isnot [string] -or $package.properties.version -cne $spec.package.version -or
        $package.properties.provisioningState -isnot [string] -or $package.properties.provisioningState -cne 'Succeeded' -or
        $package.properties.default -isnot [bool] -or $package.properties.default){throw 'Runtime package identity/import is not qualified.'}
    return $true
}
Export-ModuleMember -Function Get-AutomationRuntimeContract,Get-AutomationPackageContentLink,Assert-AutomationRuntimeReadback
