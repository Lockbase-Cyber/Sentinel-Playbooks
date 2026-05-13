@description('Name of the Microsoft.Web/connections resource the access policy attaches to.')
param connectionName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Principal ID of the Logic App system-assigned managed identity that needs to use the connection.')
param principalId string

@description('Tenant ID for the managed identity principal.')
param tenantId string = subscription().tenantId

#disable-next-line BCP081
resource existingConnection 'Microsoft.Web/connections@2016-06-01' existing = {
  name: connectionName
}

#disable-next-line BCP081
resource sentinelConnAccessPolicy 'Microsoft.Web/connections/accessPolicies@2016-06-01' = {
  parent: existingConnection
  name: principalId
  location: location
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        tenantId: tenantId
        objectId: principalId
      }
    }
  }
}
