#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ContainerAppName,
    [string]$ResourceGroupName,
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$message = @"
Hosted-surface publish is a placeholder in this scaffold.

The wrapper can already provision the Container App path, but the final hosted
artifact publication step still needs to be wired to upstream dashboard packaging
outputs.

Inputs received:
  ResourceGroupName: $ResourceGroupName
  ContainerAppName:  $ContainerAppName
"@

if ($PlanOnly) {
    Write-Output $message
    return
}

throw $message
