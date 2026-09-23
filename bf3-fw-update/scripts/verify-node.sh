#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

node=${1:-}
validate_node "$node"
require_command oc
require_maintenance_pod "$node"
pod=$(pod_for_node "$node")
artifact_dir=$(artifact_dir_for_node "$node")
output=$artifact_dir/post-update-verification.tsv

note "Verifying all targets on $node"
oc exec -n "$NS" "$pod" -- env \
    TARGET_FW="$TARGET_FW" \
    TARGET_PSID="$TARGET_PSID" \
    TARGET_OPN="$TARGET_OPN" \
    TARGET_MODE="$TARGET_MODE" \
    /usr/local/libexec/bf3-fw-update/verify-node.sh "$node" |
    tee "$output"

case $node in
    dell-b200-01)
        frontend_pf=0000:bc:00.1
        frontend_iface=ens33f1np1
        ;;
    dell-b200-02)
        frontend_pf=0000:5f:00.1
        frontend_iface=ens39f1np1
        ;;
esac

note "Verifying the excluded frontend path remains present"
oc exec -n "$NS" "$pod" -- bash -lc \
    "lspci -s '$frontend_pf' -nn; ethtool -i '$frontend_iface'; ip -br link show '$frontend_iface'" |
    tee "$artifact_dir/frontend-verification.txt"

note "Node verification passed; output saved below $artifact_dir"

