#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<'EOF'
Usage:
  install-device.sh NODE PF_BDF --confirm NODE/PF_BDF
      [--config-remote /work/bf.cfg] [--legacy-bfb-install]

The default writer is doca-installer. --legacy-bfb-install selects the direct
bfb-install flow instead. Never run both for the same device.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi

node=${1:-}
pf=${2:-}
shift $(( $# >= 2 ? 2 : $# ))
confirmation=
config_remote=
legacy=false

while (($#)); do
    case $1 in
        --confirm)
            (($# >= 2)) || die "--confirm requires NODE/PF_BDF"
            confirmation=$2
            shift 2
            ;;
        --config-remote)
            (($# >= 2)) || die "--config-remote requires a path"
            config_remote=$2
            shift 2
            ;;
        --legacy-bfb-install)
            legacy=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

validate_node "$node"
validate_target_pf "$node" "$pf"
[[ $confirmation == "$node/$pf" ]] ||
    die "write confirmation mismatch; use --confirm $node/$pf"
if [[ -n $config_remote ]]; then
    [[ $config_remote == /work/* && $config_remote != *..* ]] ||
        die "configuration must be an exact path below /work"
fi

require_command oc
require_maintenance_pod "$node"
pod=$(pod_for_node "$node")

note "Running mandatory preflight for $node $pf"
preflight=$($SCRIPT_DIR/preflight-device.sh "$node" "$pf")
printf '%s\n' "$preflight"
fw=$(sed -n 's/^FW=//p' <<<"$preflight")
rshim=$(sed -n 's/^RSHIM=//p' <<<"$preflight")
[[ $fw != "$TARGET_FW" ]] || die "$pf already reports target firmware $TARGET_FW"
[[ -n $rshim ]] || die "preflight did not return an RShim device"

writer=doca-installer
$legacy && writer=bfb-install
note "Writing $BFB_NAME to $node $pf through $rshim with $writer"

oc exec -i -n "$NS" "$pod" -- bash -s -- \
    "$BFB_NAME" "$rshim" "$config_remote" "$writer" <<'REMOTE_SCRIPT'
set -euo pipefail
bfb_name=$1
rshim=$2
config_remote=$3
writer=$4
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
log=/work/install-${rshim}-${timestamp}.log

if pgrep -x doca-installer >/dev/null || pgrep -x bfb-install >/dev/null; then
    echo "ERROR: another firmware installer process is active" >&2
    exit 1
fi
if [[ -n $config_remote && ! -f $config_remote ]]; then
    echo "ERROR: configuration file does not exist: $config_remote" >&2
    exit 1
fi

if [[ $writer == doca-installer ]]; then
    args=(doca-installer -b "/work/$bfb_name" --rshim "$rshim")
    [[ -z $config_remote ]] || args+=(-c "$config_remote")
else
    args=(bfb-install --bfb "/work/$bfb_name" --rshim "$rshim" --keep-log)
    [[ -z $config_remote ]] || args+=(--config "$config_remote")
fi

printf 'Command:' | tee "$log"
printf ' %q' "${args[@]}" | tee -a "$log"
printf '\n' | tee -a "$log"
set -o pipefail
"${args[@]}" 2>&1 | tee -a "$log"
printf '%s\n' "$log" >/work/last-install-log
REMOTE_SCRIPT

log=$(oc exec -n "$NS" "$pod" -- cat /work/last-install-log)
if oc exec -n "$NS" "$pod" -- grep -Eqi \
    'requires? a host power cycle|host power cycle.*required' "$log"; then
    echo "ACTION REQUIRED: installer requested a host power cycle." >&2
    echo "Use the planned graceful shutdown and iDRAC cold-power procedure." >&2
    exit 20
fi

note "Waiting for $pf to become queryable after installation"
ready=false
for _ in $(seq 1 36); do
    if oc exec -n "$NS" "$pod" -- flint -d "$pf" q >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 5
done
$ready || die "$pf did not become queryable within 180 seconds"

row=$(oc exec -n "$NS" "$pod" -- \
    /usr/local/libexec/bf3-fw-update/inventory-rshim.sh |
    awk -F '\t' -v pf="$pf" 'NR > 1 && $3 == pf {print; exit}')
[[ -n $row ]] || die "$pf is absent from the post-install RShim inventory"
IFS=$'\t' read -r post_rshim mgmt actual_pf psid post_fw opn mode iface <<<"$row"

[[ $psid == "$TARGET_PSID" ]] || die "post-install PSID changed to $psid"
[[ $opn == "$TARGET_OPN" ]] || die "post-install OPN changed to $opn"
[[ $mode == "$TARGET_MODE" ]] || die "post-install mode is $mode, expected $TARGET_MODE"
if [[ $post_fw != "$TARGET_FW" ]]; then
    echo "ACTION REQUIRED: $pf still reports firmware $post_fw." >&2
    echo "Review $log and use iDRAC if activation requires a cold power cycle." >&2
    exit 21
fi

note "$node $pf successfully reports $TARGET_FW in $TARGET_MODE"
