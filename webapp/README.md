# Agreement Content Viewer

Minimal Express web app that queries the Cosmos DB container used by the agreement-extraction Logic App and renders the `content` field of every document in a table.

## Run locally

```powershell
cd webapp
copy .env.example .env
# edit .env and set COSMOS_KEY (or leave blank to use `az login` / managed identity)
npm install
npm start
```

Open http://localhost:3000.

## Configuration

| Env var            | Default                                              | Notes                                     |
| ------------------ | ---------------------------------------------------- | ----------------------------------------- |
| `COSMOS_ENDPOINT`  | `https://moumoacosmosdb.documents.azure.com:443/`    | From `logicapp/connections.json`.         |
| `COSMOS_DATABASE`  | `contracts`                                          | Matches `infra/main.bicep`.               |
| `COSMOS_CONTAINER` | `agreementMetadata`                                  | Matches `infra/main.bicep`.               |
| `COSMOS_KEY`       | _(unset)_                                            | If set, uses key auth; otherwise AAD.     |
| `PORT`             | `3000`                                               | HTTP listen port.                         |

## Query

The server runs `SELECT c.id, c.content FROM c` against the container and returns the JSON array at `GET /api/items`.
