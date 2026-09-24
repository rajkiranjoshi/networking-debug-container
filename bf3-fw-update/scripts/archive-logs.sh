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
archive_name=bf3-fw-update-logs-$node.tgz
local_archive=$destination/$archive_name
partial_archive=$local_archive.partial
rm -f "$partial_archive"
trap 'rm -f "$partial_archive"' EXIT

note "Creating a non-secret log archive; BFBs and bf.cfg are excluded"
oc exec -i -n "$NS" "$pod" -- bash -s >"$partial_archive" <<'REMOTE_SCRIPT'
set -euo pipefail
args=(tar --ignore-failed-read --warning=no-file-changed
    --exclude='*.bfb' --exclude='bf.cfg' --exclude='*bf.cfg'
    -czf - -C /work .)
if [[ -d /var/log/doca_installer_logs &&
      ! /var/log/doca_installer_logs -ef /work/doca-installer-logs ]]; then
    args+=(-C /var/log doca_installer_logs)
fi
shopt -s nullglob
bfb_status_logs=(/tmp/bfb-install-*.log)
if ((${#bfb_status_logs[@]} != 0)); then
    args+=(-C /tmp "${bfb_status_logs[@]##*/}")
fi
"${args[@]}"
REMOTE_SCRIPT

mv "$partial_archive" "$local_archive"
trap - EXIT
archive_hash=$(portable_sha256 "$local_archive")
printf '%s  %s\n' "$archive_hash" "$archive_name" |
    tee "$local_archive.sha256"

note "Archived logs to $destination"
