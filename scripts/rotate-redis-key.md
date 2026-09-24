# Runbook: rotate the Redis access key used by APIM

Azure Cache for Redis has Microsoft Entra ID enabled for every client except APIM. APIM's
external cache only accepts a connection string, so it uses one access key. Terraform reads that
key at apply time (an ephemeral `listKeys` call) and writes it to APIM as a write-only value, so
the key is never stored in Terraform state, plan files or the repo.

Two keys exist (primary and secondary). Rotate by moving APIM to the other key first, then
regenerating the old one, so APIM never holds a revoked key.

## Steps (example: APIM currently on `primary`)

1. **Move APIM to the secondary key.** In `infra/terraform/envs/<env>/platform.auto.tfvars`:

   ```hcl
   redis_apim_key    = "secondary"
   redis_key_version = "1"
   ```

   Open a PR and let the pipeline plan and apply. The plan shows only `module.platform.azapi_resource.apim_cache`
   changing (its `sensitive_body_version`), and APIM gets the secondary-key connection string.

2. **Check the overflow counters still work.** In the APIM gateway logs, `x-daas-pool` should
   still show overflow pools under load (or run load test 4 in nonprod). Cache errors mean APIM
   isn't connected.

3. **Regenerate the primary key** (no longer in use):

   ```bash
   az redis regenerate-keys -g <rg> -n <redis-name> --key-type Primary
   ```

4. **Next rotation:** go back the other way. Set `redis_apim_key = "primary"`, apply, then
   regenerate the secondary key.

## If a key was regenerated while APIM was using it

APIM loses its connection and the overflow counters stop, but requests still go to the home pools.
To recover, bump `redis_key_version` (for example `"1"` → `"2"`) and apply. Terraform re-reads
the current key and re-sends the connection string.

## Entra ID access for other clients

Operators or other services never need a key: add them to `redis_entra_access` (object ID and
`Data Owner`, `Data Contributor` or `Data Reader`) and apply.
