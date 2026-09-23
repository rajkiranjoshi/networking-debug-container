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
inventory=$artifact_dir/rshim-pci-inventory.tsv

oc exec -n "$NS" "$pod" -- \
    /usr/local/libexec/bf3-fw-update/inventory-rshim.sh | tee "$inventory"

count=0
failures=0
while IFS=$'\t' read -r row_node pf mgmt iface; do
    [[ -n ${row_node:-} && $row_node != \#* ]] || continue
    [[ $row_node == "$node" ]] || continue
    count=$((count + 1))

    row=$(awk -F '\t' -v pf="$pf" 'NR > 1 && $3 == pf {print; exit}' "$inventory")
    if [[ -z $row ]]; then
        echo "ERROR: missing target $pf" >&2
        failures=$((failures + 1))
        continue
    fi
    IFS=$'\t' read -r rshim actual_mgmt actual_pf psid fw opn mode actual_iface \
        <<<"$row"

    [[ $actual_mgmt == "$mgmt" ]] || {
        echo "ERROR: $pf management BDF is $actual_mgmt, expected $mgmt" >&2
        failures=$((failures + 1))
    }
    [[ $psid == "$TARGET_PSID" ]] || {
        echo "ERROR: $pf PSID is $psid" >&2
        failures=$((failures + 1))
    }
    [[ $opn == "$TARGET_OPN" ]] || {
        echo "ERROR: $pf OPN is $opn" >&2
        failures=$((failures + 1))
    }
    [[ $mode == "$TARGET_MODE" ]] || {
        echo "ERROR: $pf mode is $mode" >&2
        failures=$((failures + 1))
    }
    [[ $actual_iface == "$iface" ]] || {
        echo "ERROR: $pf interface is $actual_iface, expected $iface" >&2
        failures=$((failures + 1))
    }
    [[ $fw == "$CURRENT_FW" || $fw == "$TARGET_FW" ]] || {
        echo "ERROR: $pf firmware is unexpected: $fw" >&2
        failures=$((failures + 1))
    }
done <"$TARGETS_FILE"

[[ $count -eq $TARGET_COUNT_PER_NODE ]] ||
    die "target table has $count rows for $node, expected $TARGET_COUNT_PER_NODE"
[[ $failures -eq 0 ]] || die "$failures inventory checks failed"

note "Validated all $count targets; inventory saved to $inventory"

