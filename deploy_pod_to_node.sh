#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <node_name>"
    exit 1
fi

node_name=$1
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

# Apply manifest with dynamic podName and nodeName substitution
echo "Deploying pod '$pod_name' to node: $node_name"
sed -e "s/REPLACE_POD_NAME/$pod_name/" -e "s/REPLACE_NODE_NAME/$node_name/" networking-debug-pod.yaml | kubectl apply -f -

echo "✓ Pod deployment initiated. Check status with: kubectl get pod $pod_name -n default"

