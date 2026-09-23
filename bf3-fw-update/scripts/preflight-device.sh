#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

node=${1:-}
pf=${2:-}
validate_node "$node"
validate_target_pf "$node" "$pf"
require_command oc
require_maintenance_pod "$node"
pod=$(pod_for_node "$node")

[[ $(oc get node "$node" -o jsonpath='{.spec.unschedulable}') == true ]] ||
    die "$node is not cordoned"

expected_mgmt=$(expected_mgmt_for_pf "$node" "$pf")
expected_iface=$(expected_iface_for_pf "$node" "$pf")
row=$(oc exec -n "$NS" "$pod" -- \
    /usr/local/libexec/bf3-fw-update/inventory-rshim.sh |
    awk -F '\t' -v pf="$pf" 'NR > 1 && $3 == pf {print; exit}')
[[ -n $row ]] || die "$pf has no live RShim mapping"

IFS=$'\t' read -r rshim mgmt actual_pf psid fw opn mode iface <<<"$row"
[[ $mgmt == "$expected_mgmt" ]] || die "$pf maps through $mgmt, expected $expected_mgmt"
[[ $actual_pf == "$pf" ]] || die "live PF mismatch: $actual_pf"
[[ $psid == "$TARGET_PSID" ]] || die "$pf PSID is $psid"
[[ $opn == "$TARGET_OPN" ]] || die "$pf OPN is $opn"
[[ $mode == "$TARGET_MODE" ]] || die "$pf is not in NIC mode: $mode"
[[ $iface == "$expected_iface" ]] || die "$pf interface is $iface, expected $expected_iface"
[[ $fw == "$CURRENT_FW" || $fw == "$TARGET_FW" ]] || die "$pf firmware is unexpected: $fw"

remote_hash=$(oc exec -n "$NS" "$pod" -- sha256sum "/work/$BFB_NAME" |
    awk '{print $1}')
[[ $remote_hash == "$BFB_SHA256" ]] || die "remote BFB hash mismatch"

vfs=$(oc exec -n "$NS" "$pod" -- bash -lc \
    "f=/sys/bus/pci/devices/$pf/sriov_numvfs; test -r \"\$f\" && cat \"\$f\" || echo N/A")
[[ $vfs == 0 ]] || die "$pf has sriov_numvfs=$vfs"

if oc exec -n "$NS" "$pod" -- bash -lc \
    'pgrep -x doca-installer >/dev/null || pgrep -x bfb-install >/dev/null'; then
    die "another firmware installer process is active"
fi

cat <<EOF
NODE=$node
PF=$pf
MGMT=$mgmt
IFACE=$iface
RSHIM=$rshim
PSID=$psid
OPN=$opn
FW=$fw
MODE=$mode
VFS=$vfs
EOF

