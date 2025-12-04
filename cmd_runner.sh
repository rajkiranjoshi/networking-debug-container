#!/bin/bash 

if [ $# -ne 1 ]; then
    echo "Usage: $0 <command>"
    exit 1
fi

# List of nodes to run the script on
nodes=(
    "pokprod-b93r39s1"
    "pokprod-b93r43s3"
    "pokprod-b93r44s0"
    "pokprod-b93r44s1"
    "pokprod-b93r44s2"
)


# Argument is the command to run on the nodes
cmd=$1

# Run the command on each node
for node in "${nodes[@]}"; do
    echo "Running command on $node"
    pod_name="networking-debug-pod-$node"
    kubectl exec -it $pod_name -n default -- /bin/bash -c "$cmd"
    echo "---------------------------------------"
done
