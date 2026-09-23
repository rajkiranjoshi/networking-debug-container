# GPU–NIC Bandwidth Matrix Test

Measures intra-host RDMA bandwidth between each GPU and each NIC on a single node using **localhost loopback** on one `networking-debug-pod`.

For every GPU × NIC pair:

1. **Server** — `ib_write_bw` on the NIC with host memory, bound to **NIC NUMA**
2. **Client** — `ib_write_bw` on the same NIC with `--use_cuda` / `--use_rocm`, bound to **GPU NUMA**

Same-NUMA GPU–NIC pairs should show higher bandwidth than cross-NUMA pairs.

## Why `ib_write_bw`?

Unlike latency tests, `ib_write_bw` supports GPU-pinned memory (`--use_cuda`). Default RDMA op is **write** (client pushes to server). Use `"rdma_op": "read"` for `ib_read_bw` if needed.

## Prerequisites

1. Deploy the debug pod on the target node:
   ```bash
   ./deploy_pod_to_node.sh <node_name> --namespace <namespace>
   ```

2. Ensure `ib_write_bw` is available in the pod.

## Configuration

```json
{
    "namespace": "default",
    "pod": "networking-debug-pod-aks-gpunp-12730235-vmss000000",
    "gpus": ["0", "1", "2", "3", "4", "5", "6", "7"],
    "nics": ["mlx5_0", "mlx5_1", "mlx5_2", "mlx5_3", "mlx5_4", "mlx5_5", "mlx5_6", "mlx5_7"],
    "msg_size": 1048576,
    "num_qps": 4,
    "num_iters": 5000
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `namespace` | Kubernetes namespace | required |
| `node` / `pod` | Target node or pod name | one required |
| `gpus` | GPU indices | required |
| `nics` | HCA device names | required |
| `msg_size` | Message size in bytes | `1048576` (1 MiB) |
| `num_qps` | Queue pairs | `4` |
| `num_iters` | Iterations per test | `5000` |
| `duration` | Test duration in seconds (mutually exclusive with `num_iters`) | — |
| `gpu_type` | `"cuda"` or `"rocm"` | `"cuda"` |
| `rdma_op` | `"write"` or `"read"` | `"write"` |
| `localhost_target` | Client connection target | `127.0.0.1` |
| `server_startup_delay` | Seconds after starting server | `2.0` |

## Usage

```bash
cd intra_node_tests/gpu-nic-bandwidth

uv run ./gpu_nic_bandwidth.py 8gpu-8nic-aks-h100.json
uv run ./gpu_nic_bandwidth.py --json 8gpu-8nic-aks-h100.json
```

## Output

Human mode prints:

1. **Average Bandwidth** matrix (Gbps)
2. **Peak Bandwidth** matrix when using `num_iters` (use `--no-peak` to skip)

JSON mode includes `matrix_avg_gbps`, `matrix_peak_gbps`, and per-pair `results`.

Exit code: `0` if all pairs succeed, `1` if any fail.

## How It Works

1. Resolve pod name from `node` or `pod` config field
2. Verify the pod is Running
3. Start **all servers in parallel** (host memory, NIC NUMA, unique port per pair)
4. Run **clients serially** (GPU memory, GPU NUMA)
5. Print average (+ peak when using `num_iters`) bandwidth matrices
