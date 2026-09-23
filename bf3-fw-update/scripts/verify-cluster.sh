#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

node=${1:-}
confirmation=${2:-}
validate_node "$node"
[[ $confirmation == --confirm-idrac ]] ||
    die "rerun with --confirm-idrac after verifying console and power control for both nodes"

require_command oc

note "Current-user authorization"
[[ $(oc auth can-i use securitycontextconstraints.security.openshift.io/privileged) == yes ]] ||
    die "current user cannot use scc/privileged"
if ! oc get namespace "$NS" >/dev/null 2>&1; then
    [[ $(oc auth can-i create namespaces) == yes ]] ||
        die "namespace $NS does not exist and current user cannot create namespaces"
fi
[[ $(oc auth can-i create pods -n "$NS") == yes ]] ||
    die "current user cannot create pods in $NS"

note "Node operating systems"
oc get nodes dell-b200-01 dell-b200-02 \
    -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,OS_IMAGE:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion'

for candidate in dell-b200-01 dell-b200-02; do
    ready=$(oc get node "$candidate" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    [[ $ready == True ]] || die "$candidate is not Ready"
    os_image=$(oc get node "$candidate" -o jsonpath='{.status.nodeInfo.osImage}')
    [[ $os_image == *'Red Hat Enterprise Linux CoreOS 9.8'* ]] ||
        die "unexpected OS image on $candidate: $os_image"
done

note "Cluster and MachineConfigPool health"
oc get clusterversion version
oc get machineconfigpool "$MCP"
mcp_degraded=$(oc get machineconfigpool "$MCP" \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')
mcp_updating=$(oc get machineconfigpool "$MCP" \
    -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}')
[[ $mcp_degraded == False && $mcp_updating == False ]] ||
    die "MachineConfigPool $MCP is degraded or updating"

unhealthy=$(oc get clusteroperators \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Available")].status}{"\t"}{.status.conditions[?(@.type=="Progressing")].status}{"\t"}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' |
    awk '$2 != "True" || $3 == "True" || $4 == "True" {print}')
if [[ -n $unhealthy ]]; then
    echo "$unhealthy" >&2
    die "one or more ClusterOperators are unavailable, progressing, or degraded"
fi

note "Network Operator absence"
if oc get customresourcedefinitions.apiextensions.k8s.io -o name |
    grep -Eiq 'sriov|nicclusterpolic|nvidianetwork'; then
    die "SR-IOV or NVIDIA Network Operator CRDs now exist; reassess this temporary workflow"
fi

note "Verified recovery access and healthy prerequisites for $node"
