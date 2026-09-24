# Load tests (nonprod, before go-live)

k6 scripts for the six scenarios in `docs/design.md` (Security, observability, capacity and testing).

| # | Script | Pass criteria |
| --- | --- | --- |
| 1 | `01-baseline.js` | All tenants at committed peak, zero 429s |
| 2 | `02-noisy-tenant.js` | One tenant at 5× limit; other tenants' p95 and 429 rate flat |
| 3 | `03-member-loss.js` + `disable-member.sh` | Disable one critical member: traffic shifts to the other two within the trip window |
| 4 | `04-cell-exhaustion.js` | Driving a pool past 90% spills to its own zone's overflow pool (`x-daas-pool`), with no gateway 429s for capacity; critical is unaffected by a general surge |
| 5 | `05-large-documents.js` | 2,000-page PDFs; GET budget holds |
| 6 | `06-key-rotation.js` + `scripts/rotate-signing-key.sh` | No result 404s across a key rotation |

## Running

```bash
# Tokens are fetched at run time and never committed.
cat > tokens.json <<JSON
{ "3f1c0d8e-0000-0000-0000-000000000901": "<token>", "3f1c0d8e-0000-0000-0000-000000000902": "<token>" }
JSON
export GATEWAY=https://apim-daas-np.azure-api.net/di/v1  # the existing APIM instance's (private) gateway host TOKENS_FILE=tokens.json DOC_URL=<urlSource>
k6 run -e PEAKS='{"3f1c0d8e-0000-0000-0000-000000000901":2,"3f1c0d8e-0000-0000-0000-000000000902":6}' 01-baseline.js
```

Run from a host inside the private network: the gateway has no public endpoint. Judge tests 3 and 4 with `queries.kql`, because DI logs carry no tenant.
