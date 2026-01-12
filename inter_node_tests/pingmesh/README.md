# Pingmesh - RoCE Cluster NIC Connectivity Test

Tests connectivity between all pairs of NICs across nodes in a Kubernetes cluster with RoCE backend network.

## Pre-requisites

Deploy the `networking-debug-pod` to all nodes before running the test:

```bash
# From the repo root, deploy to each node
./deploy_pod_to_node.sh <node_name> --namespace <namespace>
```

## Configuration

Create a JSON config file (see `roce_cluster_info.json` for example):

```json
{
    "namespace": "raj-network-debug",
    "nodes": ["10.0.65.77", "10.0.66.42", "..."],
    "interfaces": ["rdma0", "rdma1", "rdma2", "..."],
    "max_workers": 10
}
```

| Field | Description |
|-------|-------------|
| `namespace` | Kubernetes namespace where pods are deployed |
| `nodes` | List of node names (must match pod naming: `networking-debug-pod-<node>`) |
| `interfaces` | List of network interface names (same across all nodes) |
| `max_workers` | Optional. Concurrent test threads (default: 10) |

## Usage

```bash
uv run ./pingmesh.py roce_cluster_info.json
```

## Output

- **Connectivity Matrix**: Shows `success/total` NIC pairs for each node pair
- **Summary**: Overall statistics
- **Failure Details**: Specific NIC pairs that failed (if any)

Exit code: `0` if all tests pass, `1` if any failures.
