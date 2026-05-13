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
// The Sentinel managed API rejects connections that set BOTH
// 'parameterValueType: Alternative' AND 'parameterValueSet' — it returns
// InvalidApiConnectionApiReference at deploy time. We use the canonical
// Microsoft-published Sentinel playbook shape: parameterValueType +
// empty customParameterValues, no parameterValueSet.
#disable-next-line BCP081
resource sentinelConnection 'Microsoft.Web/connections@2018-07-01-preview' = {
  name: '${logicAppName}-azuresentinel'
  location: location
  tags: tags
  kind: 'V1'
  properties: {
    displayName: '${logicAppName} Sentinel (MI)'
    customParameterValues: {}
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
