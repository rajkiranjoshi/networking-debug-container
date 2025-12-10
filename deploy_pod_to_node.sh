#!/bin/bash

# Parse arguments
gpu_count=0
node_name=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --request-gpus)
            gpu_count="$2"
            shift 2
            ;;
        *)
            if [ -z "$node_name" ]; then
                node_name="$1"
            else
                echo "Error: Unknown argument '$1'"
                echo "Usage: $0 <node_name> [--request-gpus <N>]"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$node_name" ]; then
    echo "Usage: $0 <node_name> [--request-gpus <N>]"
    echo ""
    echo "Arguments:"
    echo "  <node_name>              Name of the Kubernetes node to deploy the pod on"
    echo "  --request-gpus <N>       Optional: Number of GPUs to request (default: 0)"
    exit 1
fi

pod_name="networking-debug-pod-$node_name"

# Check if pod already exists
if kubectl get pod "$pod_name" -n default &>/dev/null; then
    echo "⚠️  Pod '$pod_name' already exists in namespace 'default'"
    echo ""
    read -p "Do you want to delete the existing pod and deploy a new one? (y/n): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment aborted by user."
        exit 0
    fi
    
    echo "Deleting existing pod..."
    kubectl delete pod "$pod_name" -n default
    echo "Waiting for pod to be fully deleted..."
    kubectl wait --for=delete pod/"$pod_name" -n default --timeout=60s 2>/dev/null || true
fi

# Apply manifest with dynamic podName, nodeName, and GPU count substitution
echo "Deploying pod '$pod_name' to node: $node_name (requesting $gpu_count GPUs)"
sed -e "s/REPLACE_POD_NAME/$pod_name/" -e "s/REPLACE_NODE_NAME/$node_name/" -e "s/REPLACE_GPU_COUNT/$gpu_count/" networking-debug-pod.yaml | kubectl apply -f -

echo "✓ Pod deployment initiated. Check status with: kubectl get pod $pod_name -n default"

