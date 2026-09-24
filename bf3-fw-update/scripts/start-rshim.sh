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

rshim_state=$(oc exec -n "$NS" "$pod" -- bash -lc '
    state=absent
    if [[ -r /work/rshim.pid ]]; then
        read -r pid </work/rshim.pid || true
        if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
           [[ $(cat "/proc/$pid/comm" 2>/dev/null || true) == rshim ]]; then
            process_state=$(ps -o stat= -p "$pid" 2>/dev/null | awk "{print \$1}")
            if [[ -n $process_state && $process_state != Z* ]]; then
                state=running
            else
                state=stale
                rm -f /work/rshim.pid
            fi
        else
            state=stale
            rm -f /work/rshim.pid
        fi
    fi
    printf "%s\n" "$state"')
if [[ $rshim_state == running ]]; then
    die "RShim is already running in $NS/$pod"
fi

device_count=$(oc exec -n "$NS" "$pod" -- bash -lc \
    'shopt -s nullglob; files=(/dev/rshim*/misc); echo ${#files[@]}')
if ((device_count != 0)); then
    die "pre-existing RShim devices found without this pod's tracked daemon"
fi

missing_libraries=$(oc exec -n "$NS" "$pod" -- ldd /usr/sbin/rshim |
    awk '/not found/ {print}')
[[ -z $missing_libraries ]] || {
    printf '%s\n' "$missing_libraries" >&2
    die "RShim has unresolved runtime libraries"
}

expected_mgmt=()
while IFS= read -r mgmt; do
    expected_mgmt+=("$mgmt")
done < <(awk -F '\t' -v node="$node" \
    '$1 == node {print $3}' "$TARGETS_FILE")
[[ ${#expected_mgmt[@]} -eq $TARGET_COUNT_PER_NODE ]] ||
    die "target table has ${#expected_mgmt[@]} management functions for $node"

note "Starting RShim without force takeover"
oc exec -n "$NS" "$pod" -- bash -lc '
    set -euo pipefail
    nohup stdbuf -oL -eL /usr/sbin/rshim -b pcie -f -l 3 \
        >/work/rshim.log 2>&1 </dev/null &
    echo $! >/work/rshim.pid'

missing=("${expected_mgmt[@]}")
for _ in $(seq 1 15); do
    observed=$(oc exec -n "$NS" "$pod" -- bash -lc '
        shopt -s nullglob
        for misc in /dev/rshim*/misc; do
            sed -n "s/^DEV_NAME[[:space:]]*pcie-//p" "$misc"
        done')
    missing=()
    for mgmt in "${expected_mgmt[@]}"; do
        grep -Fxq "$mgmt" <<<"$observed" || missing+=("$mgmt")
    done
    ((${#missing[@]} == 0)) && break
    sleep 2
done

oc exec -n "$NS" "$pod" -- cat /work/rshim.log

forced=()
if ((${#missing[@]} != 0)); then
    printf 'WARNING: approved RShim mappings are owned by another backend: %s\n' \
        "${missing[*]}" >&2
    printf 'WARNING: validating each conflict before a target-specific -F takeover\n' >&2

    for mgmt in "${missing[@]}"; do
        force_index=$(oc exec -n "$NS" "$pod" -- bash -lc '
            for index in $(seq 0 127); do
                if [[ ! -e /dev/rshim${index}/misc ]]; then
                    printf "%s\n" "$index"
                    exit 0
                fi
            done
            exit 1') || die "no free RShim endpoint index for $mgmt"
        [[ $force_index =~ ^[0-9]+$ ]] ||
            die "invalid RShim endpoint index for $mgmt: $force_index"

        tag=${mgmt//[:.]/-}
        check_log=/work/rshim-force-check-$tag.log
        oc exec -n "$NS" "$pod" -- bash -lc '
            bdf=$1
            index=$2
            log=$3
            set +e
            timeout 8 /usr/sbin/rshim -b pcie -d "pcie-$bdf" \
                -i "$index" -f -l 4 >"$log" 2>&1
            rc=$?
            set -e
            printf "%s\n" "$rc" >"$log.rc"
        ' _ "$mgmt" "$force_index" "$check_log"

        check_output=$(oc exec -n "$NS" "$pod" -- cat "$check_log")
        printf '%s\n' "$check_output"
        grep -Fqi 'another backend already attached' <<<"$check_output" ||
            die "$mgmt did not confirm another backend; refusing force takeover"

        printf 'WARNING: using target-specific -F takeover for approved device %s as rshim%s\n' \
            "$mgmt" "$force_index" >&2
        oc exec -n "$NS" "$pod" -- bash -lc '
            set -euo pipefail
            bdf=$1
            index=$2
            node=$3
            tag=${bdf//[:.]/-}
            log=/work/rshim-force-$tag.log
            pidfile=/work/rshim-force-$tag.pid
            audit=/work/rshim-force-takeovers.tsv
            misc=/dev/rshim${index}/misc

            [[ ! -e $misc ]]
            nohup stdbuf -oL -eL /usr/sbin/rshim -b pcie \
                -d "pcie-$bdf" -i "$index" -f -F -l 4 \
                >"$log" 2>&1 </dev/null &
            pid=$!
            echo "$pid" >"$pidfile"

            cleanup=yes
            trap '\''
                if [[ $cleanup == yes ]]; then
                    kill "$pid" 2>/dev/null || true
                    rm -f "$pidfile"
                fi
            '\'' EXIT

            for _ in $(seq 1 20); do
                [[ -e $misc ]] && break
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.5
            done
            [[ -e $misc ]]
            kill -0 "$pid" 2>/dev/null
            actual=$(sed -n "s/^DEV_NAME[[:space:]]*//p" "$misc")
            [[ $actual == "pcie-$bdf" ]]

            result=force-flag-started
            if grep -Fq "received ownership transfer ack" "$log"; then
                result=ownership-transfer-acknowledged
            fi
            if [[ ! -s $audit ]]; then
                printf "TIMESTAMP_UTC\tNODE\tMGMT_BDF\tRSHIM\tPID\tRESULT\tLOG\n" >"$audit"
            fi
            printf "%s\t%s\t%s\trshim%s\t%s\t%s\t%s\n" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$node" "$bdf" \
                "$index" "$pid" "$result" "$log" >>"$audit"
            cleanup=no
        ' _ "$mgmt" "$force_index" "$node" || {
            oc exec -n "$NS" "$pod" -- cat "/work/rshim-force-$tag.log" >&2 || true
            die "target-specific force takeover failed for $mgmt"
        }

        oc exec -n "$NS" "$pod" -- cat "/work/rshim-force-$tag.log"
        forced+=("$mgmt")
    done

    for _ in $(seq 1 10); do
        observed=$(oc exec -n "$NS" "$pod" -- bash -lc '
            shopt -s nullglob
            for misc in /dev/rshim*/misc; do
                sed -n "s/^DEV_NAME[[:space:]]*pcie-//p" "$misc"
            done')
        missing=()
        for mgmt in "${expected_mgmt[@]}"; do
            grep -Fxq "$mgmt" <<<"$observed" || missing+=("$mgmt")
        done
        ((${#missing[@]} == 0)) && break
        sleep 1
    done
fi

((${#missing[@]} == 0)) ||
    die "missing approved RShim mappings after targeted takeover: ${missing[*]}"

if ((${#forced[@]} != 0)); then
    printf 'WARNING: target-specific -F takeover was required for: %s\n' \
        "${forced[*]}" >&2
    note "Force-takeover audit: /work/rshim-force-takeovers.tsv"
    oc exec -n "$NS" "$pod" -- cat /work/rshim-force-takeovers.tsv
elif oc exec -n "$NS" "$pod" -- grep -qi \
    'another backend already attached' /work/rshim.log; then
    printf 'WARNING: another backend was reported only for non-approved devices; no force takeover was used\n' >&2
fi

note "RShim discovered all $TARGET_COUNT_PER_NODE approved target mappings"
