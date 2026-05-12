@description('Principal ID of the Logic App system-assigned managed identity.')
param logicAppPrincipalId string

// Microsoft Sentinel Responder
// https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#microsoft-sentinel-responder
var sentinelResponderRoleId = 'ab8e14d6-4a74-4a29-9ba8-549422addade'

resource sentinelResponder 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, logicAppPrincipalId, sentinelResponderRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      sentinelResponderRoleId
    )
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output sentinelResponderAssignmentId string = sentinelResponder.id
