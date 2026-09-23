#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

node=${1:-}
confirmation=${2:-}
validate_node "$node"
[[ $confirmation == --confirm-drain ]] ||
    die "draining evicts workloads; rerun with --confirm-drain"

require_command oc
note "Cordoning $node"
oc adm cordon "$node"

note "Draining $node without force or eviction bypass"
oc adm drain "$node" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout=30m

