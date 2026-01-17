# Multi-NIC IB Write Bandwidth Test

Runs `ib_write_bw` tests across multiple src-dst NIC pairs simultaneously to measure aggregate RDMA throughput.

## Pre-requisites

1. Deploy the `networking-debug-pod` to all nodes:
   ```bash
   ./deploy_pod_to_node.sh <node_name> --namespace <namespace>
   ```

2. Ensure `ib_write_bw` (perftest) is available in the pods.

## Configuration

Create a JSON config file (see `multi_nic_info.json` for example):

```json
{
    "namespace": "raj-network-debug",
    "msg_size": 1048576,
    "num_qps": 4,
    "duration": 10,
    "bi_directional": false,
    "test_pairs": [
        {
            "src_pod": "networking-debug-pod-10.0.65.77",
            "src_hca": "mlx5_0",
            "dst_pod": "networking-debug-pod-10.0.66.42",
            "dst_hca": "mlx5_0"
        }
    ]
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `namespace` | Kubernetes namespace | required |
| `msg_size` | Message size in bytes | 1048576 (1MB) |
| `num_qps` | Number of queue pairs | 4 |
| `duration` | Test duration in seconds | 10 |
| `bi_directional` | Enable bi-directional test | false |
| `test_pairs` | List of src-dst pairs | required |

### Test Pair Fields

| Field | Description |
|-------|-------------|
| `src_pod` | Source pod name |
| `src_hca` | Source HCA device (e.g., mlx5_0) |
| `src_gpu` | Optional: Source GPU index for GPUDirect |
| `dst_pod` | Destination pod name |
| `dst_hca` | Destination HCA device |
| `dst_gpu` | Optional: Destination GPU index for GPUDirect |

## Usage

```bash
uv run ./multi_nic_ib_write_bw.py multi_nic_info.json
```

## How It Works

1. **Endpoint Discovery**: Finds network interface and IP for each HCA
2. **Start Servers**: Launches all `ib_write_bw` servers simultaneously
3. **Start Clients**: Launches all clients in parallel after servers are ready
4. **Collect Results**: Parses JSON output from each test
5. **Report**: Shows per-pair and aggregate throughput

## Output

- Per-pair bandwidth (average and peak in Gbps)
- Aggregate throughput across all pairs
- Per-NIC average throughput

Exit code: `0` if all tests pass, `1` if any failures.
