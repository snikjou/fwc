// Simple Express server that fetches documents from Cosmos DB
// and exposes the 'content' field via /api/items, plus a static HTML viewer.

const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env') });
const express = require('express');
const { CosmosClient } = require('@azure/cosmos');
const { DefaultAzureCredential } = require('@azure/identity');

const PORT = process.env.PORT || 3000;

// Defaults match the pre-existing Cosmos DB provisioned by infra/main.bicep
// (database: contracts, container: agreementMetadata) and the Logic App's
// connection in logicapp/connections.json.
const endpoint = process.env.COSMOS_ENDPOINT || 'https://agreementscosmosdb2.documents.azure.com:443/';
const databaseId = process.env.COSMOS_DATABASE || 'contracts';
const containerId = process.env.COSMOS_CONTAINER || 'agreementMetadata';
const connectionString = process.env.COSMOS_CONNECTION_STRING;
const key = process.env.COSMOS_KEY;
const useAad = /^true$/i.test(process.env.COSMOS_USE_AAD || '');

let client;
let authMode;
let configError;

if (connectionString) {
  client = new CosmosClient(connectionString);
  authMode = 'connection-string';
} else if (key) {
  client = new CosmosClient({ endpoint, key });
  authMode = 'key';
} else if (useAad) {
  client = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() });
  authMode = 'aad';
} else {
  configError =
    'Cosmos credentials are not configured. Set COSMOS_CONNECTION_STRING or COSMOS_KEY. ' +
    'Set COSMOS_USE_AAD=true only if Azure AD credentials are available.';
}

const container = client ? client.database(databaseId).container(containerId) : null;

const app = express();
app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/items', async (_req, res) => {
  if (configError) {
    return res.status(500).json({ error: configError });
  }

  try {
    // Documents store their fields at the top level (not under a `content`
    // field), so select the whole document and strip Cosmos system fields.
    const { resources } = await container.items
      .query('SELECT * FROM c')
      .fetchAll();
    const items = resources.map(doc => {
      const clean = {};
      for (const [k, v] of Object.entries(doc)) {
        if (!k.startsWith('_')) clean[k] = v;
      }
      return clean;
    });
    res.json(items);
  } catch (err) {
    console.error('Cosmos query failed:', err);
    const message = String(err && err.message ? err.message : err);
    if (/ChainedTokenCredential authentication failed/i.test(message)) {
      return res.status(500).json({
        error:
          'Azure AD authentication failed. Use COSMOS_CONNECTION_STRING or COSMOS_KEY for local dev, ' +
          'or configure Azure auth and set COSMOS_USE_AAD=true.'
      });
    }
    res.status(500).json({ error: message });
  }
});

app.get('/healthz', (_req, res) => res.send('ok'));

app.listen(PORT, () => {
  console.log(`Web app listening on http://localhost:${PORT}`);
  console.log(`Cosmos: ${endpoint} db=${databaseId} container=${containerId}`);
  console.log(`Cosmos auth mode: ${authMode}`);
});
