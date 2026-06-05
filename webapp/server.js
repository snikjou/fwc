// Simple Express server that fetches documents from Cosmos DB
// and exposes the 'content' field via /api/items, plus a static HTML viewer.

require('dotenv').config();
const path = require('path');
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
const key = process.env.COSMOS_KEY;

// Prefer key auth when a key is provided (matches the Logic App's current setup);
// otherwise fall back to AAD via DefaultAzureCredential (managed identity, az login, etc.).
const client = key
  ? new CosmosClient({ endpoint, key })
  : new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() });

const container = client.database(databaseId).container(containerId);

const app = express();
app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/items', async (_req, res) => {
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
    res.status(500).json({ error: err.message });
  }
});

app.get('/healthz', (_req, res) => res.send('ok'));

app.listen(PORT, () => {
  console.log(`Web app listening on http://localhost:${PORT}`);
  console.log(`Cosmos: ${endpoint} db=${databaseId} container=${containerId}`);
});
