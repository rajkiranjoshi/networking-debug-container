# Pingmesh - RoCE Cluster NIC Connectivity Test

Tests connectivity between all pairs of NICs across nodes/pods in a Kubernetes cluster with RoCE backend network.

## Modes

The script supports two modes:

1. **Nodes mode**: Uses `networking-debug-pod` pods deployed to each node (pod names derived as `networking-debug-pod-<node>`)
2. **Pods mode**: Uses existing pods directly (pods must have `ping` from iputils installed)

## Pre-requisites

### For Nodes Mode

Deploy the `networking-debug-pod` to all nodes before running the test:

```bash
# From the repo root, deploy to each node
./deploy_pod_to_node.sh <node_name> --namespace <namespace>
```

### For Pods Mode

Ensure the target pods have `ping` from **iputils** installed and available in the container. The script uses:
```bash
ping -A -I <src_ip> <dst_ip> -c 3 -W 2
```

## Configuration

Create a JSON config file. Use either `nodes` or `pods` (not both).

### Nodes Mode (see `cluster_info-nodes.json`)

```json
{
    "namespace": "raj-network-debug",
    "nodes": ["10.0.65.77", "10.0.66.42", "..."],
    "interfaces": ["rdma0", "rdma1", "rdma2", "..."],
    "max_workers": 10
}
```

### Pods Mode (see `cluster_info-pods.json`)

```json
{
    "namespace": "llm-d-wide-ep",
    "pods": ["pod-name-1", "pod-name-2", "..."],
    "interfaces": ["net1-0", "net1-1", "net1-2", "..."],
    "max_workers": 5
}
```

### Config Fields

| Field | Description |
|-------|-------------|
| `namespace` | Kubernetes namespace where pods are deployed |
| `nodes` | List of node names (pod name derived as `networking-debug-pod-<node>`) |
| `pods` | List of pod names to use directly (mutually exclusive with `nodes`) |
| `interfaces` | List of network interface names (same across all nodes/pods) |
| `max_workers` | Optional. Concurrent test threads (default: 10) |

## Usage

```bash
# Nodes mode
uv run ./pingmesh.py cluster_info-nodes.json

# Pods mode
uv run ./pingmesh.py cluster_info-pods.json
```

## Output

- **Connectivity Matrix**: Shows `success/total` NIC pairs for each node/pod pair
- **Summary**: Overall statistics
- **Failure Details**: Specific NIC pairs that failed (if any)

Exit code: `0` if all tests pass, `1` if any failures.
