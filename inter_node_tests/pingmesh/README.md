# Pingmesh - Network Connectivity Test

Tests connectivity between all pairs of NICs across nodes/pods in a Kubernetes cluster.

Supports two network types:
- **RoCE** (default): ICMP ping between RoCE NIC IPs
- **EFA**: `fi_pingpong` over AWS EFA datapath (full NxN cross-device mesh)

## Entity Modes

1. **Nodes mode**: Uses `networking-debug-pod` pods deployed to each node (pod names derived as `networking-debug-pod-<node>`)
2. **Pods mode**: Uses existing pods directly

## Pre-requisites

Deploy the `networking-debug-pod` to all nodes before running the test:

```bash
# From the repo root, deploy to each node
./deploy_pod_to_node.sh <node_name> --namespace <namespace>
```

For RoCE: pods must have `ping` (iputils) installed.
For EFA: pods must have `fi_pingpong` (libfabric fabtests) installed, with EFA devices exposed via the EFA device plugin. Pods should use `hostNetwork: true`.

## Configuration

Create a JSON config file. Use either `nodes` or `pods` (not both).

### RoCE Config

```json
{
    "namespace": "raj-network-debug",
    "network_type": "roce",
    "nodes": ["10.0.65.77", "10.0.66.42"],
    "interfaces": ["rdma0", "rdma1", "rdma2"],
    "max_workers": 10
}
```

### EFA Config (see `pingmesh-eks_h100.json`)

```json
{
    "namespace": "default",
    "network_type": "efa",
    "nodes": ["ip-10-12-2-177.us-west-2.compute.internal", "ip-10-12-2-214.us-west-2.compute.internal"],
    "devices": ["rdmap79s0", "rdmap80s0", "rdmap81s0", "..."],
    "max_workers": 8
}
```

### Config Fields

| Field | Description |
|-------|-------------|
| `namespace` | Kubernetes namespace where pods are deployed |
| `network_type` | `"roce"` (default) or `"efa"` |
| `nodes` | List of node names (pod name derived as `networking-debug-pod-<node>`) |
| `pods` | List of pod names to use directly (mutually exclusive with `nodes`) |
| `interfaces` | (RoCE) List of network interface names |
| `devices` | (EFA) List of EFA device names (without `-rdm` suffix) |
| `max_workers` | Concurrent test threads. RoCE default: 10. EFA max: 8 |

## Usage

```bash
# RoCE pingmesh
uv run ./pingmesh.py cluster_info-nodes.json

# EFA pingmesh (full NxN cross-device mesh)
uv run ./pingmesh.py pingmesh-eks_h100.json
```

## EFA Details

The EFA mode tests all NxN device pair combinations between nodes using `fi_pingpong`:
- For 32 EFA devices: 32x32 = 1024 tests per node pair
- Tests are batched (max 8 parallel) to avoid EFA resource exhaustion
- Each batch starts one-shot `fi_pingpong` servers, runs parallel clients, then servers auto-exit
- Estimated runtime: ~38 minutes for 1024 tests (2 nodes, 32 devices)
- Ctrl+C gracefully cleans up server processes

## Output

- **Connectivity Matrix**: Shows `success/total` NIC pairs for each node/pod pair
- **Summary**: Overall statistics
- **Failure Details**: Specific NIC/device pairs that failed (if any)

Exit code: `0` if all tests pass, `1` if any failures.
