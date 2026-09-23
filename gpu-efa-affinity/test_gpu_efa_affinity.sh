#!/bin/bash

# Test GPU-to-EFA NIC PCIe affinity by deploying a pod with a 1:4 GPU:EFA ratio
# and verifying that allocated devices share PCIe switches.
#
# Usage:
#   ./test_gpu_efa_affinity.sh <node_name> <num_gpus> [--namespace <ns>] [--image <image>]
#
# Examples:
#   ./test_gpu_efa_affinity.sh ip-10-12-2-177.us-west-2.compute.internal 1
#   ./test_gpu_efa_affinity.sh ip-10-12-2-177.us-west-2.compute.internal 2
#   ./test_gpu_efa_affinity.sh ip-10-12-2-177.us-west-2.compute.internal 4
#   ./test_gpu_efa_affinity.sh ip-10-12-2-177.us-west-2.compute.internal 8

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AFFINITY_SCRIPT="$SCRIPT_DIR/check_gpu_efa_affinity.sh"

node_name=""
num_gpus=""
namespace="default"
image="quay.io/rajjoshi/networking-debug-container:efa"

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            namespace="$2"
            shift 2
            ;;
        --image)
            image="$2"
            shift 2
            ;;
        *)
            if [ -z "$node_name" ]; then
                node_name="$1"
            elif [ -z "$num_gpus" ]; then
                num_gpus="$1"
            else
                echo "Error: Unknown argument '$1'"
                echo "Usage: $0 <node_name> <num_gpus> [--namespace <ns>] [--image <image>]"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$node_name" ] || [ -z "$num_gpus" ]; then
    echo "Usage: $0 <node_name> <num_gpus> [--namespace <ns>] [--image <image>]"
    echo ""
    echo "Deploys a pod requesting <num_gpus> GPUs and 4x EFA NICs, then checks PCIe alignment."
    echo ""
    echo "Arguments:"
    echo "  <node_name>     Kubernetes node name to deploy on"
    echo "  <num_gpus>      Number of GPUs to request (EFA NICs = 4 x num_gpus)"
    echo "  -n, --namespace Kubernetes namespace (default: default)"
    echo "  --image         Container image (default: quay.io/rajjoshi/networking-debug-container:efa)"
    exit 1
fi

num_efa=$((num_gpus * 4))
pod_name="gpu-efa-affinity-test-${num_gpus}gpu-${node_name}"

# Kubernetes names must be <= 63 chars and lowercase
pod_name=$(echo "$pod_name" | tr '[:upper:]' '[:lower:]' | cut -c1-63)

echo "=== GPU-EFA PCIe Affinity Test ==="
echo "  Node:      $node_name"
echo "  GPUs:      $num_gpus"
echo "  EFA NICs:  $num_efa (4x)"
echo "  Pod:       $pod_name"
echo "  Namespace: $namespace"
echo ""

# Clean up any existing pod
if kubectl get pod "$pod_name" -n "$namespace" &>/dev/null; then
    echo "Deleting existing pod '$pod_name'..."
    kubectl delete pod "$pod_name" -n "$namespace" --wait=true 2>/dev/null || true
fi

# Generate and apply the pod manifest
echo "Deploying test pod..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${namespace}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  nodeSelector:
    kubernetes.io/hostname: "${node_name}"
  containers:
  - name: affinity-test
    image: ${image}
    imagePullPolicy: Always
    resources:
      limits:
        nvidia.com/gpu: "${num_gpus}"
        vpc.amazonaws.com/efa: "${num_efa}"
      requests:
        nvidia.com/gpu: "${num_gpus}"
        vpc.amazonaws.com/efa: "${num_efa}"
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    command: ["/bin/bash", "-c", "sleep infinity"]
EOF

# Wait for pod to be running
echo "Waiting for pod to be ready..."
if ! kubectl wait --for=condition=Ready pod/"$pod_name" -n "$namespace" --timeout=120s; then
    echo "ERROR: Pod failed to start. Status:"
    kubectl get pod "$pod_name" -n "$namespace" -o wide
    kubectl describe pod "$pod_name" -n "$namespace" | tail -20
    exit 1
fi

echo "Pod is running. Checking GPU-EFA PCIe affinity..."
echo ""

# Copy the affinity check script into the pod and run it
kubectl cp "$AFFINITY_SCRIPT" "$namespace/$pod_name:/tmp/check_gpu_efa_affinity.sh"
exit_code=0
kubectl exec "$pod_name" -n "$namespace" -- bash /tmp/check_gpu_efa_affinity.sh || exit_code=$?

echo ""

# Cleanup
echo "Cleaning up test pod..."
kubectl delete pod "$pod_name" -n "$namespace" --wait=false

exit $exit_code
