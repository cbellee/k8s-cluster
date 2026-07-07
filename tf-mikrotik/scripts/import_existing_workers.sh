#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/import_existing_workers.sh <instance-id> <template-id> <peer-id-wk01> <peer-id-wk02> <peer-id-wk03>
# Example:
#   ./scripts/import_existing_workers.sh '*1' '*2' '*A' '*B' '*C'

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <instance-id> <template-id> <peer-id-wk01> <peer-id-wk02> <peer-id-wk03>" >&2
  exit 1
fi

INSTANCE_ID="$1"
TEMPLATE_ID="$2"
PEER1_ID="$3"
PEER2_ID="$4"
PEER3_ID="$5"

terraform import routeros_routing_bgp_instance.k8s "$INSTANCE_ID"
terraform import routeros_routing_bgp_template.k8s "$TEMPLATE_ID"
terraform import 'routeros_routing_bgp_connection.k8s_peers["kube-wk-01"]' "$PEER1_ID"
terraform import 'routeros_routing_bgp_connection.k8s_peers["kube-wk-02"]' "$PEER2_ID"
terraform import 'routeros_routing_bgp_connection.k8s_peers["kube-wk-03"]' "$PEER3_ID"

echo "Import complete. Run: terraform plan"
