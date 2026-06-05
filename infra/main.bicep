// ============================================================
// Agreement Extraction – Logic App Standard full deployment
// Resources provisioned:
//   - Storage Account (Logic App host storage)
//   - App Service Plan (Workflow Standard WS1)
//   - Logic App Standard (with System Managed Identity)
//   - Azure Blob Storage container for incoming agreements
//   - Document Intelligence account
//   - Azure Cosmos DB (NoSQL) account + database + container
//   - RBAC role assignments (Managed Identity → each data service)
// ============================================================

@description('Short environment suffix, e.g. dev / test / prod')
param environmentName string = 'dev'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Name prefix applied to all resources')
param appName string = 'agreement-extraction'

@description('Azure Blob container that acts as the agreement inbox')
param agreementBlobContainer string = 'agreements'

@description('Cosmos DB database name')
param cosmosDbDatabase string = 'contracts'

@description('Cosmos DB container name')
param cosmosDbContainer string = 'agreementMetadata'

@description('Cosmos DB partition key path')
param cosmosPartitionKey string = '/agreementIdentifier'

@description('OpenAI endpoint (must already exist; no new OpenAI resource is provisioned here)')
param openAiEndpoint string

@description('OpenAI GPT-4 deployment name')
param openAiDeployment string = 'gpt-4.1-mini'

// ── Name helpers ─────────────────────────────────────────────
var suffix       = uniqueString(resourceGroup().id, appName, environmentName)
var saName       = 'st${take(replace(appName, '-', ''), 8)}${take(suffix, 8)}'  // max 24 chars
var planName     = 'plan-${appName}-${environmentName}'
var logicAppName = 'la-${appName}-${environmentName}'
var docIntelName = 'docintel-${appName}-${environmentName}'
var cosmosName   = 'cosmos-${appName}-${environmentName}'
var blobSaName   = 'stblob${take(suffix, 10)}'                                  // separate SA for blobs

// ── Storage Account for Logic App host ───────────────────────
resource hostStorage 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  name: saName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    // Disable shared-key access; Logic App uses identity-based access
    allowSharedKeyAccess: false
  }
}

// ── Blob Storage Account for agreement files ─────────────────
resource blobStorage 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  name: blobSaName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-04-01' = {
  parent: blobStorage
  name: 'default'
}

resource agreementContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-04-01' = {
  parent: blobService
  name: agreementBlobContainer
  properties: {
    publicAccess: 'None'
  }
}

// ── Workflow Standard App Service Plan ───────────────────────
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  properties: {}
}

// ── Logic App Standard ───────────────────────────────────────
resource logicApp 'Microsoft.Web/sites@2023-12-01' = {
  name: logicAppName
  location: location
  kind: 'workflowapp,functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName',           value: hostStorage.name }
        { name: 'AzureWebJobsStorage__blobServiceUri',        value: hostStorage.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri',       value: hostStorage.properties.primaryEndpoints.queue }
        { name: 'AzureWebJobsStorage__tableServiceUri',       value: hostStorage.properties.primaryEndpoints.table }
        { name: 'AzureWebJobsStorage__credential',            value: 'managedidentity' }
        // Identity-based content share (no shared keys). Do NOT set WEBSITE_CONTENTAZUREFILECONNECTIONSTRING when using MI.
        { name: 'WEBSITE_CONTENTOVERVNET',                    value: '0' }
        { name: 'FUNCTIONS_EXTENSION_VERSION',                value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',                   value: 'node' }
        { name: 'APP_KIND',                                   value: 'workflowApp' }
        // Cosmos DB key consumed by logicapp/connections.json -> @appsetting('CosmosDB_Key')
        { name: 'CosmosDB_Key',                               value: cosmosAccount.listKeys().primaryMasterKey }
        // ── Workflow parameters (referenced as @appsetting('...')) ──
        { name: 'BLOB_ACCOUNT_NAME',                          value: blobStorage.name }
        { name: 'BLOB_CONTAINER',                             value: agreementBlobContainer }
        { name: 'DOC_INTEL_ENDPOINT',                         value: docIntel.properties.endpoint }
        { name: 'OPENAI_ENDPOINT',                            value: openAiEndpoint }
        { name: 'OPENAI_DEPLOYMENT',                          value: openAiDeployment }
        { name: 'COSMOS_ACCOUNT',                             value: cosmosAccount.name }
        { name: 'COSMOS_DATABASE',                            value: cosmosDbDatabase }
        { name: 'COSMOS_CONTAINER',                           value: cosmosDbContainer }
      ]
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
  }
  dependsOn: [
    hostStorage
  ]
}

// ── Document Intelligence ─────────────────────────────────────
resource docIntel 'Microsoft.CognitiveServices/accounts@2024-04-01-preview' = {
  name: docIntelName
  location: location
  sku: { name: 'S0' }
  kind: 'FormRecognizer'
  identity: { type: 'SystemAssigned' }
  properties: {
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true         // enforce managed identity only
  }
}

// ── Cosmos DB ─────────────────────────────────────────────────
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosName
  location: location
  kind: 'GlobalDocumentDB'
  identity: { type: 'SystemAssigned' }
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [{ locationName: location, failoverPriority: 0, isZoneRedundant: false }]
    enableFreeTier: false
    disableKeyBasedMetadataWriteAccess: true
    disableLocalAuth: false        // Logic App connector needs key access for now
    capabilities: []
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmosAccount
  name: cosmosDbDatabase
  properties: {
    resource: { id: cosmosDbDatabase }
    options: { throughput: 400 }
  }
}

resource cosmosDbContainerResource 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: cosmosDatabase
  name: cosmosDbContainer
  properties: {
    resource: {
      id: cosmosDbContainer
      partitionKey: {
        paths: [ cosmosPartitionKey ]
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [ { path: '/*' } ]
        excludedPaths: [ { path: '/"_etag"/?' } ]
      }
    }
  }
}

// ── RBAC role assignments ─────────────────────────────────────

// Logic App MI → host Storage Account (Storage Blob Data Owner)
resource roleHostBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostStorage.id, logicApp.id, 'StorageBlobDataOwner')
  scope: hostStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleHostQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostStorage.id, logicApp.id, 'StorageQueueDataContributor')
  scope: hostStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleHostTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostStorage.id, logicApp.id, 'StorageTableDataContributor')
  scope: hostStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Logic App MI → agreements Blob Storage (Storage Blob Data Reader)
resource roleBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(blobStorage.id, logicApp.id, 'StorageBlobDataReader')
  scope: blobStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Logic App MI → Document Intelligence (Cognitive Services User)
resource roleDocIntelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(docIntel.id, logicApp.id, 'CognitiveServicesUser')
  scope: docIntel
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4dca-a6dd-f0fce3d2adc5')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ───────────────────────────────────────────────────
output logicAppName string = logicApp.name
output logicAppUrl string = 'https://${logicApp.properties.defaultHostName}'
output blobStorageName string = blobStorage.name
output blobContainerName string = agreementBlobContainer
output docIntelEndpoint string = docIntel.properties.endpoint
output cosmosAccountName string = cosmosAccount.name
output cosmosDbDatabase string = cosmosDatabase.name
output cosmosDbContainer string = cosmosDbContainerResource.name
