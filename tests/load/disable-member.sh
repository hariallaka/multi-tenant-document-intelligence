#!/usr/bin/env bash
# Simulate member loss for load test 3 by rejecting the DI private endpoint connection.
# Usage: disable-member.sh <resource-group> <di-account-name> [--restore]
set -euo pipefail
rg="$1"; account="$2"; action="${3:-}"
id=$(az cognitiveservices account show -g "$rg" -n "$account" --query id -o tsv)
conn=$(az network private-endpoint-connection list --id "$id" --query "[0].id" -o tsv)
if [[ "$action" == "--restore" ]]; then
  az network private-endpoint-connection approve --id "$conn" --description "load test 3 restore"
else
  az network private-endpoint-connection reject --id "$conn" --description "load test 3 member loss"
fi
