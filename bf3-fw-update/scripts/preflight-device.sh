#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

status_green=
status_red=
status_reset=
if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
    status_green=$'\033[1;32m'
    status_red=$'\033[1;31m'
    status_reset=$'\033[0m'
fi

ok() {
    printf '  %-72s %bOK%b\n' "$*" "$status_green" "$status_reset" >&2
}

die() {
    printf '  %-72s %bFAIL%b\n' "$*" "$status_red" "$status_reset" >&2
    exit 1
}

node=${1:-}
pf=${2:-}
validate_node "$node"
validate_target_pf "$node" "$pf"
ok "Approved target: $node $pf"
require_command oc
require_maintenance_pod "$node"
pod=$(pod_for_node "$node")
ok "Maintenance Pod is running: $NS/$pod"

[[ $(oc get node "$node" -o jsonpath='{.spec.unschedulable}') == true ]] ||
    die "$node is not cordoned"
ok "Node is cordoned"

expected_mgmt=$(expected_mgmt_for_pf "$node" "$pf")
expected_iface=$(expected_iface_for_pf "$node" "$pf")
row=$(oc exec -n "$NS" "$pod" -- \
    /usr/local/libexec/bf3-fw-update/inventory-rshim.sh |
    awk -F '\t' -v pf="$pf" 'NR > 1 && $3 == pf {print; exit}')
[[ -n $row ]] || die "$pf has no live RShim mapping"

IFS=$'\t' read -r rshim mgmt actual_pf psid fw opn mode iface <<<"$row"
[[ $mgmt == "$expected_mgmt" ]] || die "$pf maps through $mgmt, expected $expected_mgmt"
[[ $actual_pf == "$pf" ]] || die "live PF mismatch: $actual_pf"
ok "Live RShim mapping verified: $rshim -> $mgmt -> $pf"
[[ $psid == "$TARGET_PSID" ]] || die "$pf PSID is $psid"
[[ $opn == "$TARGET_OPN" ]] || die "$pf OPN is $opn"
ok "Device identity verified: PSID=$psid OPN=$opn"
[[ $mode == "$TARGET_MODE" ]] || die "$pf is not in NIC mode: $mode"
[[ $iface == "$expected_iface" ]] || die "$pf interface is $iface, expected $expected_iface"
[[ $fw == "$CURRENT_FW" || $fw == "$TARGET_FW" ]] || die "$pf firmware is unexpected: $fw"
ok "NIC mode, interface, and firmware state verified: $mode $iface FW=$fw"

remote_hash=$(oc exec -n "$NS" "$pod" -- sha256sum "/work/$BFB_NAME" |
    awk '{print $1}')
[[ $remote_hash == "$BFB_SHA256" ]] || die "remote BFB hash mismatch"
ok "Staged BFB image exists and SHA-256 matches: /work/$BFB_NAME"

vf_info=$(oc exec -n "$NS" "$pod" -- bash -lc '
    pf=$1
    device=/sys/bus/pci/devices/$pf
    vfs_file=$device/sriov_numvfs
    shopt -s nullglob
    active_vfs=("$device"/virtfn*)
    if [[ -r $vfs_file ]]; then
        vfs=$(<"$vfs_file")
    else
        vfs=N/A
    fi
    printf "%s\t%s\n" "$vfs" "${#active_vfs[@]}"
' _ "$pf")
IFS=$'\t' read -r vfs active_vfs <<<"$vf_info"
[[ $active_vfs == 0 ]] || die "$pf has $active_vfs active SR-IOV VFs"
case $vfs in
    0|N/A) ;;
    *) die "$pf has sriov_numvfs=$vfs" ;;
esac
ok "SR-IOV is safe: sriov_numvfs=$vfs active_vfs=$active_vfs"

installer_state=$(oc exec -n "$NS" "$pod" -- bash -lc '
    if pgrep -x doca-installer >/dev/null || pgrep -x bfb-install >/dev/null; then
        echo active
    else
        echo idle
    fi')
if [[ $installer_state == active ]]; then
    die "another firmware installer process is active"
fi
ok "No firmware installer process is active"
ok "Preflight passed for $node $pf"

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
