#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <node_name>"
    exit 1
fi

node_name=$1

# Check if pod already exists
if kubectl get pod networking-debug-pod -n default &>/dev/null; then
    echo "⚠️  Pod 'networking-debug-pod' already exists in namespace 'default'"
    echo ""
    read -p "Do you want to delete the existing pod and deploy a new one? (y/n): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment aborted by user."
        exit 0
    fi
    
    echo "Deleting existing pod..."
    kubectl delete pod networking-debug-pod -n default
    echo "Waiting for pod to be fully deleted..."
    kubectl wait --for=delete pod/networking-debug-pod -n default --timeout=60s 2>/dev/null || true
fi

# Apply manifest with dynamic nodeName substitution
echo "Deploying pod to node: $node_name"
sed "s/REPLACE_NODE_NAME/$node_name/" networking-debug-pod.yaml | kubectl apply -f -

echo "✓ Pod deployment initiated. Check status with: kubectl get pod networking-debug-pod -n default"

