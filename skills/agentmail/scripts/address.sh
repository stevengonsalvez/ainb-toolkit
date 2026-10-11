#!/usr/bin/env bash
# Print the address for a slug. Usage: address.sh <slug>
source "$(dirname "$0")/_lib.sh"
STATE=$(require_state "${1:-}")
jq -r .address "$STATE"
