#requires -Version 7.0
#requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications
<#
.SYNOPSIS
  Grants the MDI playbook Graph app permissions to the Logic App's managed identity.
.DESCRIPTION
  PowerShell variant of grant-graph-permissions.sh. Use this when you prefer
  Microsoft.Graph PowerShell modules over the bash + az rest approach.
  Run this once, post-deploy, signed in as a Privileged Role Administrator or
  Global Admin.
.PARAMETER LogicAppPrincipalId
  The system-assigned MI principal ID emitted as `managedIdentityPrincipalId`
  from the main deployment.
.EXAMPLE
  pwsh -File ./grant-graph-permissions.ps1 -LogicAppPrincipalId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $LogicAppPrincipalId
)

$ErrorActionPreference = 'Stop'

$graphAppId = '00000003-0000-0000-c000-000000000000'
$rolesWanted = @(
  'SecurityIdentitiesAccount.Read.All'
  'SecurityIdentitiesUserActions.ReadWrite.All'
)

Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All" | Out-Null

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
if (-not $graphSp) { throw 'Could not find Microsoft Graph service principal.' }

foreach ($roleName in $rolesWanted) {
  $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName }
  if (-not $appRole) {
    throw "App role '$roleName' not found on Microsoft Graph SP."
  }

  $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $LogicAppPrincipalId |
    Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }

  if ($existing) {
    Write-Host "[$roleName] already granted, skipping"
    continue
  }

  New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $LogicAppPrincipalId `
    -PrincipalId $LogicAppPrincipalId `
    -ResourceId $graphSp.Id `
    -AppRoleId $appRole.Id | Out-Null

  Write-Host "[$roleName] granted"
}

Disconnect-MgGraph | Out-Null
