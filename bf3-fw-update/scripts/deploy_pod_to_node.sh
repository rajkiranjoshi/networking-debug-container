#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

node=${1:-}
image=${2:-}
validate_node "$node"
[[ -n $image ]] || die "Usage: deploy_pod_to_node.sh NODE IMAGE@sha256:DIGEST"
require_digest_image "$image"
require_command oc

pod=$(pod_for_node "$node")
template=$PROJECT_DIR/manifests/maintenance-pod.yaml.tpl

note "Creating namespace $NS if needed"
oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -

[[ $(oc auth can-i use securitycontextconstraints.security.openshift.io/privileged) == yes ]] ||
    die "current user cannot use scc/privileged"
[[ $(oc auth can-i create pods -n "$NS") == yes ]] ||
    die "current user cannot create pods in $NS"

if oc get pod -n "$NS" "$pod" >/dev/null 2>&1; then
    die "$NS/$pod already exists; inspect or delete it explicitly"
fi

[[ $(oc get node "$node" -o jsonpath='{.spec.unschedulable}') == true ]] ||
    die "$node is not cordoned; run drain-node.sh first"

note "Scheduling $NS/$pod onto cordoned node $node"
sed \
    -e "s|__POD__|$pod|g" \
    -e "s|__NAMESPACE__|$NS|g" \
    -e "s|__NODE__|$node|g" \
    -e "s|__IMAGE__|$image|g" \
    "$template" | oc apply -f -

oc wait -n "$NS" --for=condition=Ready "pod/$pod" --timeout=5m

actual_node=$(oc get pod -n "$NS" "$pod" -o jsonpath='{.spec.nodeName}')
[[ $actual_node == "$node" ]] ||
    die "$pod was scheduled on $actual_node instead of $node"

note "Verifying userspace tools and absence of a pre-existing RShim session"
oc exec -n "$NS" "$pod" -- bash -lc '
    set -euo pipefail
    test -c /dev/cuse
    test -w /work
    test -w /var/log/doca_installer_logs
    test /var/log/doca_installer_logs -ef /work/doca-installer-logs
    dpkg-query -W rshim mft doca-installer
    mst version
    missing_libraries=$(ldd /usr/sbin/rshim | awk "/not found/ {print}")
    if [[ -n $missing_libraries ]]; then
        printf "%s\n" "$missing_libraries" >&2
        echo "ERROR: RShim has unresolved runtime libraries" >&2
        exit 1
    fi
    if compgen -G "/dev/rshim*/misc" >/dev/null; then
        echo "ERROR: pre-existing RShim devices found" >&2
        exit 1
    fi'
