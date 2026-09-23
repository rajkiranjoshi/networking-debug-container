#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

node=${1:-}
confirmation=${2:-}
validate_node "$node"
[[ $confirmation == --confirm-return-to-service ]] ||
    die "rerun with --confirm-return-to-service after verification and log archival"
require_command oc
pod=$(pod_for_node "$node")

note "Deleting maintenance pod $NS/$pod"
oc delete pod -n "$NS" "$pod" --wait=true

note "Uncordoning $node"
oc adm uncordon "$node"
oc wait --for=condition=Ready "node/$node" --timeout=15m
oc get machineconfigpool "$MCP"
oc get node "$node" -o wide

