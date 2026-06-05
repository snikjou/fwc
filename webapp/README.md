# Agreement Content Viewer

Minimal Express web app that queries the Cosmos DB container used by the agreement-extraction Logic App and renders the `content` field of every document in a table.

## Run locally

```powershell
cd webapp
copy .env.example .env
# edit .env and set COSMOS_CONNECTION_STRING (or COSMOS_KEY)
npm install
npm start
```

Open http://localhost:3000.

## Configuration

| Env var            | Default                                              | Notes                                     |
| ------------------ | ---------------------------------------------------- | ----------------------------------------- |
| `COSMOS_ENDPOINT`  | `https://agreementscosmosdb2.documents.azure.com:443/` | Used with key/AAD auth modes.           |
| `COSMOS_DATABASE`  | `contracts`                                          | Matches `infra/main.bicep`.               |
| `COSMOS_CONTAINER` | `agreementMetadata`                                  | Matches `infra/main.bicep`.               |
| `COSMOS_CONNECTION_STRING` | _(unset)_                                   | Preferred local auth mode if set.         |
| `COSMOS_KEY`       | _(unset)_                                            | Uses endpoint + key auth if set.          |
| `COSMOS_USE_AAD`   | `false`                                              | Set `true` to use `DefaultAzureCredential`.
| `PORT`             | `3000`                                               | HTTP listen port.                         |

## Query

The server runs `SELECT * FROM c` against the container and returns a JSON array at `GET /api/items`.
