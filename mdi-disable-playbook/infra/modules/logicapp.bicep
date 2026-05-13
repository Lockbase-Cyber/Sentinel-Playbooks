@description('Name of the Logic App workflow.')
param logicAppName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Subset of ["disable","forcePasswordReset"] to execute per matched identity.')
@allowed([
  'disable'
  'forcePasswordReset'
])
param actionsToEnable array = [
  'disable'
  'forcePasswordReset'
]

@description('Resource tags.')
param tags object = {}

// Microsoft Sentinel managed API ID, regional.
var sentinelManagedApiId = subscriptionResourceId(
  'Microsoft.Web/locations/managedApis',
  location,
  'azuresentinel'
)

// API connection for Sentinel with managed-identity auth.
//
// apiVersion is pinned to 2016-06-01 because Microsoft's own Sentinel
// playbook samples (Azure/Azure-Sentinel and Azure/Microsoft-Defender-for-Cloud
// repos) use exactly this version. The 2018-07-01-preview version validated
// the connection differently and returned InvalidApiConnectionApiReference
// at deploy time even with the same property shape.
//
// Bicep's static type catalog for 2016-06-01 doesn't include 'kind' or
// 'parameterValueType' on this resource (it's an old API surface that the
// type generator didn't fully cover), so BCP037/BCP187 warnings are spurious.
// The runtime accepts these properties — verified against the published samples.
resource sentinelConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: '${logicAppName}-azuresentinel'
  location: location
  tags: tags
  #disable-next-line BCP187
  kind: 'V1'
  properties: {
    displayName: '${logicAppName} Sentinel (MI)'
    customParameterValues: {}
    #disable-next-line BCP037
    parameterValueType: 'Alternative'
    api: {
      id: sentinelManagedApiId
    }
  }
}

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('../workflow/workflow.json').definition
    parameters: {
      '$connections': {
        value: {
          azuresentinel: {
            connectionId: sentinelConnection.id
            connectionName: sentinelConnection.name
            id: sentinelManagedApiId
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
              }
            }
          }
        }
      }
      actionsToEnable: {
        value: actionsToEnable
      }
    }
  }
}

// Grant the Logic App MI access to the Sentinel API connection so it can
// authenticate as the MI when the trigger fires and when commenting back.
// The accessPolicies child resource is deployed via a nested module so that
// the Logic App's system-assigned principalId (only known at deployment time)
// can satisfy Bicep's "name must be calculable at start" rule (BCP120).
module sentinelConnAccessPolicy 'logicapp.accessPolicy.bicep' = {
  name: '${logicAppName}-sentinelAccessPolicy'
  params: {
    connectionName: sentinelConnection.name
    location: location
    principalId: logicApp.identity.principalId
    tenantId: subscription().tenantId
  }
}

output logicAppResourceId string = logicApp.id
output logicAppName string = logicApp.name
output managedIdentityPrincipalId string = logicApp.identity.principalId
output sentinelConnectionId string = sentinelConnection.id
