@description('Principal ID of the Logic App system-assigned managed identity that needs Graph perms.')
param logicAppPrincipalId string

@description('Resource ID of the user-assigned MI that has AppRoleAssignment.ReadWrite.All on Graph. Pre-provisioned manually once per subscription.')
param bootstrapManagedIdentityResourceId string

@description('Azure region.')
param location string = resourceGroup().location

@description('Resource tags.')
param tags object = {}

@description('Force-update tag for the deploymentScripts resource. Default utcNow() ensures the script re-runs on every deploy (it is idempotent inside).')
param forceUpdateTag string = utcNow()

// Microsoft Graph service principal (well-known appId).
var graphAppId = '00000003-0000-0000-c000-000000000000'

// App roles to grant. These IDs are stable across tenants — they're the appRole GUIDs on the Graph SP.
// Source: query https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?$select=appRoles
// and grep for SecurityIdentitiesAccount.Read.All / SecurityIdentitiesUserActions.ReadWrite.All.
var appRolesToGrant = [
  'SecurityIdentitiesAccount.Read.All'
  'SecurityIdentitiesUserActions.ReadWrite.All'
]

resource graphPermsScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'grant-graph-perms-${uniqueString(logicAppPrincipalId)}'
  location: location
  tags: tags
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${bootstrapManagedIdentityResourceId}': {}
    }
  }
  properties: {
    azPowerShellVersion: '11.0'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    forceUpdateTag: forceUpdateTag
    environmentVariables: [
      { name: 'TARGET_PRINCIPAL_ID', value: logicAppPrincipalId }
      { name: 'GRAPH_APP_ID', value: graphAppId }
      { name: 'APP_ROLES', value: join(appRolesToGrant, ',') }
    ]
    scriptContent: '''
$ErrorActionPreference = "Stop"
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications

Connect-MgGraph -Identity -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All" | Out-Null

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$($env:GRAPH_APP_ID)'"
if (-not $graphSp) { throw "Could not find Microsoft Graph SP" }

$rolesWanted = $env:APP_ROLES -split ","
foreach ($roleName in $rolesWanted) {
  $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName }
  if (-not $appRole) {
    throw "App role '$roleName' not found on Microsoft Graph SP (it may have been renamed)"
  }

  # Idempotent: check existing assignments first.
  $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $env:TARGET_PRINCIPAL_ID |
    Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }

  if ($existing) {
    Write-Host "[$roleName] already granted, skipping"
    continue
  }

  New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $env:TARGET_PRINCIPAL_ID `
    -PrincipalId $env:TARGET_PRINCIPAL_ID `
    -ResourceId $graphSp.Id `
    -AppRoleId $appRole.Id | Out-Null
  Write-Host "[$roleName] granted"
}

$DeploymentScriptOutputs = @{
  grantedRoles = $rolesWanted -join ","
}
'''
  }
}

output grantedRoles string = graphPermsScript.properties.outputs.grantedRoles
