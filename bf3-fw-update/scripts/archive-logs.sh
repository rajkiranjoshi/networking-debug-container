#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

node=${1:-}
destination=${2:-}
validate_node "$node"
[[ -n $destination ]] || die "Usage: archive-logs.sh NODE DESTINATION_DIRECTORY"
require_command oc
require_maintenance_pod "$node"
pod=$(pod_for_node "$node")

mkdir -p "$destination"
remote_archive=/tmp/bf3-fw-update-logs-$node.tgz

note "Creating a non-secret log archive; BFBs and bf.cfg are excluded"
oc exec -n "$NS" "$pod" -- bash -s -- "$remote_archive" <<'REMOTE_SCRIPT'
set -euo pipefail
remote_archive=$1
rm -f "$remote_archive"
args=(tar --exclude='*.bfb' --exclude='bf.cfg' --exclude='*bf.cfg'
    -czf "$remote_archive" -C /work .)
if [[ -d /var/log/doca_installer_logs ]]; then
    args+=(-C /var/log doca_installer_logs)
fi
"${args[@]}"
REMOTE_SCRIPT

oc cp "$NS/$pod:$remote_archive" "$destination/$(basename "$remote_archive")"
portable_sha256 "$destination/$(basename "$remote_archive")" |
    tee "$destination/$(basename "$remote_archive").sha256"

note "Archived logs to $destination"
