#!/usr/bin/env bash
set -euo pipefail

node=${1:?Usage: verify-node.sh NODE}
target_fw=${TARGET_FW:?TARGET_FW is required}
target_psid=${TARGET_PSID:?TARGET_PSID is required}
target_opn=${TARGET_OPN:?TARGET_OPN is required}
target_mode=${TARGET_MODE:?TARGET_MODE is required}
targets_file=/opt/bf3-fw-update/targets.tsv
inventory_file=$(mktemp)
trap 'rm -f "$inventory_file"' EXIT

/usr/local/libexec/bf3-fw-update/inventory-rshim.sh >"$inventory_file"
printf 'PF_BDF\tIFACE\tPSID\tFW\tOPN\tMODE\tDRIVER\tPCIE_LINK\tVFS\n'

failures=0
count=0
while IFS=$'\t' read -r row_node pf mgmt iface; do
    [[ -n ${row_node:-} && $row_node != \#* ]] || continue
    [[ $row_node == "$node" ]] || continue
    count=$((count + 1))

    row=$(awk -F '\t' -v pf="$pf" 'NR > 1 && $3 == pf {print; exit}' \
        "$inventory_file")
    if [[ -z $row ]]; then
        printf '%s\t%s\tMISSING\t-\t-\t-\t-\t-\t-\n' "$pf" "$iface"
        failures=$((failures + 1))
        continue
    fi

    IFS=$'\t' read -r rshim actual_mgmt actual_pf psid fw opn mode actual_iface \
        <<<"$row"
    driver=$(ethtool -i "$iface" 2>/dev/null |
        awk -F ': ' '$1 == "driver" {print $2; exit}' || true)
    link=$(lspci -s "$pf" -vv 2>/dev/null |
        sed -n 's/^[[:space:]]*LnkSta:[[:space:]]*//p' | head -1 || true)
    vfs_file=/sys/bus/pci/devices/$pf/sriov_numvfs
    if [[ -r $vfs_file ]]; then vfs=$(<"$vfs_file"); else vfs=N/A; fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pf" "$iface" "$psid" "$fw" "$opn" "$mode" \
        "${driver:--}" "${link:--}" "$vfs"

    [[ $actual_mgmt == "$mgmt" ]] || failures=$((failures + 1))
    [[ $actual_iface == "$iface" ]] || failures=$((failures + 1))
    [[ $psid == "$target_psid" ]] || failures=$((failures + 1))
    [[ $fw == "$target_fw" ]] || failures=$((failures + 1))
    [[ $opn == "$target_opn" ]] || failures=$((failures + 1))
    [[ $mode == "$target_mode" ]] || failures=$((failures + 1))
    [[ $driver == mlx5_core ]] || failures=$((failures + 1))
    [[ $link == *'Speed 32GT/s'* && $link == *'Width x16'* ]] ||
        failures=$((failures + 1))
    [[ $vfs == 0 ]] || failures=$((failures + 1))
done <"$targets_file"

[[ $count -eq 10 ]] || {
    echo "ERROR: target table contains $count entries for $node, expected 10" >&2
    exit 1
}
[[ $failures -eq 0 ]] || {
    echo "ERROR: $failures node verification checks failed" >&2
    exit 1
}
