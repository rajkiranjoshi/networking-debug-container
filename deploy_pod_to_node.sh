#!/bin/bash

# Parse arguments
nvidia_gpu_count=0
amd_gpu_count=0
node_name=""
namespace=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --request-nvidia-gpus)
            nvidia_gpu_count="$2"
            shift 2
            ;;
        --request-amd-gpus)
            amd_gpu_count="$2"
            shift 2
            ;;
        -n|--namespace)
            namespace="$2"
            shift 2
            ;;
        *)
            if [ -z "$node_name" ]; then
                node_name="$1"
            else
                echo "Error: Unknown argument '$1'"
                echo "Usage: $0 <node_name> [--namespace <namespace>] [--request-nvidia-gpus <N>] [--request-amd-gpus <N>]"
                exit 1
            fi
            shift
            ;;
    esac
done

# If namespace not specified, get it from current kubectl context
if [ -z "$namespace" ]; then
    namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)
    # If no namespace is set in the current context, fall back to "default"
    if [ -z "$namespace" ]; then
        namespace="default"
    fi
fi

if [ -z "$node_name" ]; then
    echo "Usage: $0 <node_name> [--namespace <namespace>] [--request-nvidia-gpus <N>] [--request-amd-gpus <N>]"
    echo ""
    echo "Arguments:"
    echo "  <node_name>                  Name of the Kubernetes node to deploy the pod on"
    echo "  -n, --namespace <ns>         Optional: Kubernetes namespace (default: current context namespace, or 'default')"
    echo "  --request-nvidia-gpus <N>    Optional: Number of NVIDIA GPUs to request (default: 0)"
    echo "  --request-amd-gpus <N>       Optional: Number of AMD GPUs to request (default: 0)"
    exit 1
fi

pod_name="networking-debug-pod-$node_name"

# Check if pod already exists
if kubectl get pod "$pod_name" -n "$namespace" &>/dev/null; then
    echo "⚠️  Pod '$pod_name' already exists in namespace '$namespace'"
    echo ""
    read -p "Do you want to delete the existing pod and deploy a new one? (y/n): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment aborted by user."
        exit 0
    fi
    
    echo "Deleting existing pod..."
    kubectl delete pod "$pod_name" -n "$namespace"
    echo "Waiting for pod to be fully deleted..."
    kubectl wait --for=delete pod/"$pod_name" -n "$namespace" --timeout=60s 2>/dev/null || true
fi

# Apply manifest with dynamic podName, nodeName, namespace, and GPU count substitution
echo "Deploying pod '$pod_name' to node: $node_name in namespace: $namespace"
echo "  Requesting: $nvidia_gpu_count NVIDIA GPU(s), $amd_gpu_count AMD GPU(s)"
sed -e "s/REPLACE_POD_NAME/$pod_name/" \
    -e "s/REPLACE_NODE_NAME/$node_name/" \
    -e "s/REPLACE_NAMESPACE/$namespace/" \
    -e "s/REPLACE_NVIDIA_GPU_COUNT/$nvidia_gpu_count/" \
    -e "s/REPLACE_AMD_GPU_COUNT/$amd_gpu_count/" \
    networking-debug-pod.yaml | kubectl apply -f -

echo "✓ Pod deployment initiated. Check status with: kubectl get pod $pod_name -n $namespace"

