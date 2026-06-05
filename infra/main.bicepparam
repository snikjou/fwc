using './main.bicep'

// ── Required ──────────────────────────────────────────────────
// Point to your existing Azure OpenAI resource endpoint.
// Format: https://<resource-name>.openai.azure.com
param openAiEndpoint = 'https://<your-openai-resource>.openai.azure.com'

// ── Optional – override defaults ─────────────────────────────
param environmentName    = 'dev'
param location           = 'eastus'
param appName            = 'agreement-extraction'

param agreementBlobContainer = 'agreements'
param cosmosDbDatabase       = 'documents'
param cosmosDbContainer      = 'agreements'
param cosmosPartitionKey     = '/agreementIdentifier'
param openAiDeployment       = 'gpt-4.1-mini'
