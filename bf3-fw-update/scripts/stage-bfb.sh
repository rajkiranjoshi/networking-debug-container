#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

node=${1:-}
bfb_local=${2:-}
validate_node "$node"
[[ -f $bfb_local ]] || die "BFB file not found: $bfb_local"
require_command oc
require_maintenance_pod "$node"
pod=$(pod_for_node "$node")

local_hash=$(portable_sha256 "$bfb_local")
[[ $local_hash == "$BFB_SHA256" ]] ||
    die "local BFB hash $local_hash does not match $BFB_SHA256"

remote_path=/work/$BFB_NAME
remote_hash=$(oc exec -n "$NS" "$pod" -- bash -lc \
    "test -f '$remote_path' && sha256sum '$remote_path' | awk '{print \$1}'" \
    2>/dev/null || true)
if [[ $remote_hash != "$BFB_SHA256" ]]; then
    note "Copying the 1.6-GiB BFB to $node"
    oc cp "$bfb_local" "$NS/$pod:$remote_path"
fi

remote_hash=$(oc exec -n "$NS" "$pod" -- sha256sum "$remote_path" |
    awk '{print $1}')
[[ $remote_hash == "$BFB_SHA256" ]] ||
    die "remote BFB hash $remote_hash does not match $BFB_SHA256"

note "Reading embedded target firmware catalog"
oc exec -n "$NS" "$pod" -- bash -lc \
    "set -o pipefail; doca-installer -b '$remote_path' --show-target-fw 2>&1 | tee /work/show-target-fw.txt"

catalog=$(oc exec -n "$NS" "$pod" -- cat /work/show-target-fw.txt)
grep -Fq "$TARGET_PSID" <<<"$catalog" || die "target PSID absent from BFB catalog"
grep -Fq "$TARGET_FW" <<<"$catalog" || die "target firmware absent from BFB catalog"
grep -Fq '900-9D3D4-00EN-HA0' <<<"$catalog" || die "target OPN absent from BFB catalog"

note "BFB staged and verified at $remote_path"
