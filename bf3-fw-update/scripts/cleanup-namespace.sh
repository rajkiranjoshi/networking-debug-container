#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[[ ${1:-} == --confirm-delete-namespace ]] ||
    die "rerun with --confirm-delete-namespace after both nodes pass and logs are archived"

if oc get pods -n "$NS" -o name 2>/dev/null | grep -q .; then
    die "$NS still contains pods"
fi
oc delete namespace "$NS"

echo "Host /var/mnt/tier0/bf3-fw-update directories were intentionally retained."
