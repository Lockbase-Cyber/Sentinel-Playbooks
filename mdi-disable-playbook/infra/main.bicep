targetScope = 'resourceGroup'

@description('Name of the Logic App workflow.')
param logicAppName string = 'pa-mdi-disable-${uniqueString(resourceGroup().id)}'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Resource ID of the Sentinel workspace this playbook will respond on. Used only for documentation/output — RBAC is scoped to the RG.')
param sentinelWorkspaceResourceId string

@description('Resource tags.')
param tags object = {}

@description('Subset of ["disable","forcePasswordReset"] to execute per matched identity.')
param actionsToEnable array = [
  'disable'
  'forcePasswordReset'
]

@description('If true, run the Microsoft.Resources/deploymentScripts path to auto-grant Graph permissions (requires a pre-existing bootstrap UAMI). If false (default), Graph perms must be granted post-deploy by running scripts/grant-graph-permissions.sh (Cloud Shell) or .ps1 (local). Leave false for "Deploy to Azure" button flows.')
param grantGraphPermissionsViaDeploymentScript bool = false

@description('Resource ID of a pre-existing user-assigned managed identity that has AppRoleAssignment.ReadWrite.All on Microsoft Graph. Required only when grantGraphPermissionsViaDeploymentScript is true. Leave blank for the post-deploy script path.')
param bootstrapManagedIdentityResourceId string = ''

module logicAppModule 'modules/logicapp.bicep' = {
  name: 'logicApp'
  params: {
    logicAppName: logicAppName
    location: location
    actionsToEnable: actionsToEnable
    tags: tags
  }
}

module roleAssignmentsModule 'modules/roleAssignments.bicep' = {
  name: 'roleAssignments'
  params: {
    logicAppPrincipalId: logicAppModule.outputs.managedIdentityPrincipalId
  }
}

module graphPermissionsModule 'modules/graphPermissions.bicep' = if (grantGraphPermissionsViaDeploymentScript) {
  name: 'graphPermissions'
  params: {
    logicAppPrincipalId: logicAppModule.outputs.managedIdentityPrincipalId
    bootstrapManagedIdentityResourceId: bootstrapManagedIdentityResourceId
    location: location
    tags: tags
  }
}

output logicAppResourceId string = logicAppModule.outputs.logicAppResourceId
output logicAppName string = logicAppModule.outputs.logicAppName
output managedIdentityPrincipalId string = logicAppModule.outputs.managedIdentityPrincipalId
output sentinelWorkspaceResourceIdEcho string = sentinelWorkspaceResourceId
