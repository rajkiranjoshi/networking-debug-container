# Inter-Node Testing Tools

Automated test scripts for validating network connectivity and measuring RDMA bandwidth across Kubernetes nodes.

## Prerequisites

- Debug pods deployed on target nodes using `deploy_pod_to_node.sh`
- [uv](https://github.com/astral-sh/uv) package manager for Python scripts
- `kubectl` configured with access to the cluster

## Available Tests

### Pingmesh Test (`pingmesh/`)

Tests network connectivity between all NICs across Kubernetes nodes.

```bash
cd pingmesh
uv run ./pingmesh.py roce_cluster_info.json
```

See [pingmesh/README.md](pingmesh/README.md) for configuration details.

---

### Single-NIC IB Write Bandwidth (`single_nic_ib_write_bw/`)

Run `ib_write_bw` tests between two pods on a single NIC pair.

```bash
cd single_nic_ib_write_bw

# Basic test (CPU only)
./single_nic_ib_write_bw.sh \
    --src networking-debug-pod-10.0.65.77:mlx5_0 \
    --dst networking-debug-pod-10.0.66.42:mlx5_0 \
    --msg-size 1048576 \
    --namespace my-network-debug

# With NVIDIA GPU
./single_nic_ib_write_bw.sh \
    --src networking-debug-pod-10.0.65.77:mlx5_0:0 \
    --dst networking-debug-pod-10.0.66.42:mlx5_0:0 \
    --msg-size 1048576 \
    --namespace my-network-debug

# With AMD GPU (explicit rocm type)
./single_nic_ib_write_bw.sh \
    --src networking-debug-pod-10.0.65.77:mlx5_0:rocm:0 \
    --dst networking-debug-pod-10.0.66.42:mlx5_0:rocm:0 \
    --msg-size 1048576 \
    --namespace my-network-debug
```

#### GPU Argument Format

`pod:hca[:gpu_type:gpu_index]`

| Format | Description |
|--------|-------------|
| `pod:hca` | No GPU |
| `pod:hca:0` | NVIDIA GPU 0 (cuda is default) |
| `pod:hca:cuda:0` | NVIDIA GPU 0 (explicit) |
| `pod:hca:rocm:0` | AMD GPU 0 |

#### Periodic Testing

Run repeated tests across multiple message sizes:

```bash
./single_nic_ib_write_bw-periodic.sh \
    --src networking-debug-pod-10.0.65.77:mlx5_0 \
    --dst networking-debug-pod-10.0.66.42:mlx5_0 \
    --namespace my-network-debug \
    --output results.csv
```

---

### Multi-NIC IB Write Bandwidth (`multi_nic_ib_write_bw/`)

Run simultaneous `ib_write_bw` tests across multiple NIC pairs to measure aggregate throughput.

```bash
cd multi_nic_ib_write_bw
uv run ./multi_nic_ib_write_bw.py config.json
```

See [multi_nic_ib_write_bw/README.md](multi_nic_ib_write_bw/README.md) for configuration details.

#### Example Config

```json
{
    "namespace": "my-network-debug",
    "tos": 41,
    "msg_size": 4194304,
    "num_qps": 4,
    "num_iters": 5000,
    "bi_directional": false,
    "use_hugepages": false,
    "test_pairs": [
        {
            "src_pod": "networking-debug-pod-10.0.65.77",
            "src_hca": "mlx5_0",
            "src_gpu": "0",
            "src_gpu_type": "cuda",
            "dst_pod": "networking-debug-pod-10.0.66.42",
            "dst_hca": "mlx5_0",
            "dst_gpu": "0",
            "dst_gpu_type": "cuda"
        },
        {
            "src_pod": "networking-debug-pod-10.0.65.77",
            "src_hca": "mlx5_2",
            "dst_pod": "networking-debug-pod-10.0.66.42",
            "dst_hca": "mlx5_2"
        }
    ]
}
```

#### GPU Config Fields

| Field | Description | Default |
|-------|-------------|---------|
| `src_gpu` | Source GPU index (e.g., "0") | None (no GPU) |
| `src_gpu_type` | "cuda" or "rocm" | "cuda" |
| `dst_gpu` | Destination GPU index | None (no GPU) |
| `dst_gpu_type` | "cuda" or "rocm" | "cuda" |

#### Periodic Testing

Run repeated tests across multiple message sizes:

```bash
./multi_nic_ib_write_bw-periodic.sh \
    --template 8nic-pairs_4MiB_4qp.json \
    --output results.csv
```

---

## Data Analysis (`expt_data/`)

The `expt_data/` directory contains:
- CSV files with periodic test results
- Jupyter notebook (`data-analysis.ipynb`) for analyzing and visualizing results

To run the analysis:

```bash
cd expt_data
uv run jupyter notebook data-analysis.ipynb
```
