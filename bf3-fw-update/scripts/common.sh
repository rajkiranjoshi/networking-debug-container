#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TARGETS_FILE=$PROJECT_DIR/config/targets.tsv

# shellcheck source=../config.env
source "$PROJECT_DIR/config.env"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

note() {
    echo "==> $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_node() {
    case ${1:-} in
        dell-b200-01|dell-b200-02) ;;
        *) die "node must be dell-b200-01 or dell-b200-02" ;;
    esac
}

pod_for_node() {
    printf 'bf3-fw-maintenance-%s\n' "$1"
}

target_row() {
    local node=$1 pf=$2
    awk -F '\t' -v node="$node" -v pf="$pf" \
        '$1 == node && $2 == pf {print; exit}' "$TARGETS_FILE"
}

validate_target_pf() {
    local node=$1 pf=$2 row
    row=$(target_row "$node" "$pf")
    [[ -n $row ]] || die "$pf is not an approved target on $node"
}

expected_mgmt_for_pf() {
    target_row "$1" "$2" | awk -F '\t' '{print $3}'
}

expected_iface_for_pf() {
    target_row "$1" "$2" | awk -F '\t' '{print $4}'
}

require_maintenance_pod() {
    local node=$1 pod
    pod=$(pod_for_node "$node")
    [[ $(oc get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}') == Running ]] ||
        die "maintenance pod $NS/$pod is not Running"
}

portable_sha256() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

artifact_dir_for_node() {
    local node=$1 dir=$PROJECT_DIR/artifacts/$node
    mkdir -p "$dir"
    printf '%s\n' "$dir"
}

require_digest_image() {
    local image=$1
    [[ $image == *@sha256:* ]] ||
        die "maintenance image must be pinned by digest: registry/image@sha256:..."
}

