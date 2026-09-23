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

if oc exec -n "$NS" "$pod" -- bash -lc \
    'test -r /work/rshim.pid && kill -0 "$(cat /work/rshim.pid)" 2>/dev/null'; then
    die "RShim is already running in $NS/$pod"
fi

if oc exec -n "$NS" "$pod" -- bash -lc \
    'compgen -G "/dev/rshim*/misc" >/dev/null'; then
    die "pre-existing RShim devices found without this pod's tracked daemon"
fi

note "Starting RShim without force takeover"
oc exec -n "$NS" "$pod" -- bash -lc '
    set -euo pipefail
    nohup /usr/sbin/rshim -b pcie -f -l 3 \
        >/work/rshim.log 2>&1 </dev/null &
    echo $! >/work/rshim.pid'

for _ in $(seq 1 15); do
    count=$(oc exec -n "$NS" "$pod" -- bash -lc \
        'shopt -s nullglob; files=(/dev/rshim*/misc); echo ${#files[@]}')
    [[ $count -ge $TARGET_COUNT_PER_NODE ]] && break
    sleep 2
done

oc exec -n "$NS" "$pod" -- cat /work/rshim.log
[[ ${count:-0} -ge $TARGET_COUNT_PER_NODE ]] ||
    die "RShim exposed only ${count:-0} devices; expected at least $TARGET_COUNT_PER_NODE"

if oc exec -n "$NS" "$pod" -- grep -qi 'another backend already attached' /work/rshim.log; then
    die "another backend owns one or more RShim devices; do not use --force without review"
fi

note "RShim discovered $count devices"

