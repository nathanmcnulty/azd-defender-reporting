#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$FunctionAppName,
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$message = @"
The Function App publish path is intentionally blocked in this scaffold.

This wrapper is waiting for defender-reporting to expose a first-class Function App
package build surface with a stable manifest or output path. Once that contract lands,
this script should consume that manifest and publish the package into the provisioned
Flex Consumption Function App.

Inputs received:
  ResourceGroupName: $ResourceGroupName
  FunctionAppName:   $FunctionAppName
"@

if ($PlanOnly) {
    Write-Output $message
    return
}

throw $message

