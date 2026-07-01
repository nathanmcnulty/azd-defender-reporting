#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$AutomationAccountName,
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$message = @"
Automation publish is a placeholder in this scaffold.

Provisioning for the Automation Account matrix is in place, but the wrapper still
needs the final runbook publish flow that will resolve upstream artifacts and push
them into the provisioned account.

Inputs received:
  ResourceGroupName:    $ResourceGroupName
  AutomationAccountName:$AutomationAccountName
"@

if ($PlanOnly) {
    Write-Output $message
    return
}

throw $message

