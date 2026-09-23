#!/usr/bin/env bash
# Rotate result-signing-key with overlap (design: Async result affinity, Rules).
#
#   1. result-signing-key-prev <- current value   (in-flight tickets keep verifying)
#   2. APIM refreshes result-signing-key-prev
#   3. result-signing-key      <- new random 32-byte key (base64)
#   4. APIM refreshes result-signing-key
#
# Tickets signed before the rotation verify against -prev until the next rotation,
# so rotate no more often than every 24 h. Run from a host with private access to
# Key Vault, as an identity with Key Vault Secrets Officer and APIM Service Contributor.
#
# Usage: rotate-signing-key.sh <key-vault-name> <apim-name> <resource-group>
set -euo pipefail

kv="$1"; apim="$2"; rg="$3"
sub=$(az account show --query id -o tsv)
apim_path="/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim"

refresh() {
  # Force APIM to re-read the Key Vault reference instead of waiting for its 4 h refresh.
  az rest --method post \
    --url "https://management.azure.com$apim_path/namedValues/$1/refreshSecret?api-version=2024-05-01" \
    --output none
}

wait_for_propagation() {
  echo "Waiting ${PROPAGATION_SECONDS:-120}s for gateway units to pick up $1..."
  sleep "${PROPAGATION_SECONDS:-120}"
}

current=$(az keyvault secret show --vault-name "$kv" --name result-signing-key --query value -o tsv)
az keyvault secret set --vault-name "$kv" --name result-signing-key-prev \
  --content-type "application/octet-stream;base64" --value "$current" --output none
unset current
refresh result-signing-key-prev
wait_for_propagation result-signing-key-prev

az keyvault secret set --vault-name "$kv" --name result-signing-key \
  --content-type "application/octet-stream;base64" --value "$(openssl rand -base64 32)" --output none
refresh result-signing-key
wait_for_propagation result-signing-key

echo "Rotated result-signing-key on $apim; previous key retained as result-signing-key-prev."
