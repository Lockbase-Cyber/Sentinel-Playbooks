#requires -Version 7.0
<#
.SYNOPSIS
  Validates workflow.json against the Logic Apps Workflow Definition Language schema.
#>
[CmdletBinding()]
param(
  [string] $WorkflowPath = "$PSScriptRoot/workflow.json"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $WorkflowPath)) {
  throw "workflow.json not found at $WorkflowPath"
}

$raw = Get-Content $WorkflowPath -Raw

# 1) Parses as JSON
try {
  $obj = $raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
} catch {
  throw "workflow.json is not valid JSON: $_"
}

# 2) Required top-level keys
foreach ($k in @('definition','parameters')) {
  if (-not $obj.PSObject.Properties.Name.Contains($k)) {
    throw "Missing top-level key: $k"
  }
}

# 3) Definition shape
$def = $obj.definition
foreach ($k in @('$schema','contentVersion','triggers','actions')) {
  if (-not $def.PSObject.Properties.Name.Contains($k)) {
    throw "Missing definition.$k"
  }
}

# 4) Schema URL is the current 2016-06-01 one (pin so PRs notice churn)
$expectedSchema = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
if ($def.'$schema' -ne $expectedSchema) {
  throw "Unexpected schema URL: $($def.'$schema')"
}

# 5) Graph base URL is pinned to beta via a definition-level parameter (forces single-point cutover)
if (-not $def.parameters.graphBaseUrl) {
  throw "definition.parameters.graphBaseUrl is required (single-point beta→v1.0 cutover)"
}
if ($def.parameters.graphBaseUrl.defaultValue -notmatch '/beta/security/identities/identityAccounts') {
  throw "graphBaseUrl default must point at the beta identityAccounts surface"
}

Write-Host "workflow.json: OK"
