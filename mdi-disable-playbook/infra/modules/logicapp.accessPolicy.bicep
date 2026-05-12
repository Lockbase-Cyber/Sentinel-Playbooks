@description('Name of the Microsoft.Web/connections resource the access policy attaches to.')
param connectionName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Principal ID of the Logic App system-assigned managed identity that needs to use the connection.')
param principalId string

@description('Tenant ID for the managed identity principal.')
param tenantId string = subscription().tenantId

#disable-next-line BCP081
resource existingConnection 'Microsoft.Web/connections@2018-07-01-preview' existing = {
  name: connectionName
}

#disable-next-line BCP081
resource sentinelConnAccessPolicy 'Microsoft.Web/connections/accessPolicies@2018-07-01-preview' = {
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
