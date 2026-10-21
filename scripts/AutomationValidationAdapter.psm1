#Requires -Version 7.6
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'AutomationValidationPreflight.psm1') -Force
if (-not ('AzdValidation.BoundedIO' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'BoundedValidationIO.cs') }

function Invoke-BoundedValidationChild {
    <#.SYNOPSIS
    Supervises a trusted noninteractive worker with bounded private pipes and a hard timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][Collections.IDictionary]$Message,
        [Parameter(Mandatory)][ValidateRange(1,30)][int]$TimeoutSeconds
    )
    $ErrorActionPreference='Stop'
    $file=Get-Item -LiteralPath $ScriptPath
    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid worker source.'}
    $pwsh=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
    $inputText=$Message | ConvertTo-Json -Depth 32 -Compress
    try {
        $text=[AzdValidation.BoundedIO]::Run($pwsh,$file.FullName,$inputText,$TimeoutSeconds).GetAwaiter().GetResult()
        [AzdValidation.BoundedIO]::ValidateJsonObject($text)
        $value=$text | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 32
        if($value.Count -ne 2 -or $value.ok -isnot [bool] -or -not $value.ok -or -not $value.Contains('result')){throw 'Invalid worker envelope.'}
        # JSON integer values deserialize as Int64. Validate before narrowing to the
        # lifecycle transport contract; never coerce strings, floats or Booleans.
        if($value.result -is [Collections.IDictionary]) {
            $response=$value.result
            if($response.Count -ne 2 -or -not $response.Contains('StatusCode') -or -not $response.Contains('Body') -or
                ($response.StatusCode -isnot [int] -and $response.StatusCode -isnot [long]) -or
                $response.StatusCode -lt 100 -or $response.StatusCode -gt 599 -or
                ($null -ne $response.Body -and $response.Body -isnot [Collections.IDictionary])){throw 'Invalid worker response.'}
            $response.StatusCode=[int]$response.StatusCode
        } elseif($value.result -isnot [bool] -or -not $value.result){throw 'Invalid worker result.'}
        return $value.result
    } catch {throw 'Validation worker failed or timed out; reconcile the same job if submission was possible.'}
}

function New-AutomationValidationAdapter {
    <#.SYNOPSIS
    Binds approved cell data to supervised guarded HTTP and remote-preflight callbacks.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Only constructs in-memory callbacks; does not access Azure or change state.')]
    param([Parameter(Mandatory)][Collections.IDictionary]$Context)
    Assert-ValidationContext $Context | Out-Null
    # Snapshot the context so later caller mutation cannot retarget the worker.
    $frozen=$Context | ConvertTo-Json -Depth 32 -Compress | ConvertFrom-Json -AsHashtable -Depth 32
    $worker=Join-Path $PSScriptRoot 'AutomationValidationWorker.ps1'
    $invokeChild=${function:Invoke-BoundedValidationChild}
    $assertRequest=${function:Assert-ValidationJobRequest}
    $assertContext=${function:Assert-ValidationContext}
    return @{
        Guard={param($seconds) & $invokeChild -ScriptPath $worker -Message @{action='Guard';context=$frozen;budget=$seconds} -TimeoutSeconds $seconds}.GetNewClosure()
        Preflight={param($seconds) & $invokeChild -ScriptPath $worker -Message @{action='Preflight';context=$frozen;budget=$seconds} -TimeoutSeconds $seconds}.GetNewClosure()
        Request={param($method,$uri,$body,$seconds)
            # Validate locally before any worker authentication/provider access.
            & $assertContext $frozen | Out-Null
            & $assertRequest -Context $frozen -Method $method -Uri $uri -Body $body | Out-Null
            & $invokeChild -ScriptPath $worker -Message @{action='Request';context=$frozen;method=$method;uri=$uri;body=$body;budget=$seconds} -TimeoutSeconds $seconds
        }.GetNewClosure()
    }
}
Export-ModuleMember -Function Invoke-BoundedValidationChild,New-AutomationValidationAdapter
