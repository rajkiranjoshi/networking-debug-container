# GPU–NIC Latency Matrix Test

Measures intra-host RDMA latency between each GPU and each NIC on a single node using **localhost loopback** on one `networking-debug-pod`.

For every GPU × NIC pair:

1. **Server** — `ib_read_lat` on the NIC with host memory, bound to **NIC NUMA**
2. **Client** — `ib_read_lat` on the same NIC with `--use_cuda` / `--use_rocm`, bound to **GPU NUMA**

Server and client must use different NUMA bindings so cross-NUMA GPU–NIC paths are measured correctly.
Binding the client to the NIC's NUMA node (instead of the GPU's) masks topology differences.

Same-NUMA GPU–NIC pairs should show lower median latency than cross-NUMA pairs.

## Why `ib_read_lat` instead of `ib_write_lat`?

Perftest does **not** support CUDA/ROCm memory with `ib_write_lat`. GPU-pinned latency requires `ib_read_lat` (client initiates RDMA read into GPU memory). The relative topology pattern in the matrix is the same.

## Prerequisites

1. Deploy the debug pod on the target node (if not already running):
   ```bash
   ./deploy_pod_to_node.sh <node_name> --namespace <namespace>
   ```

2. Ensure `ib_read_lat` is available in the pod (included in the networking-debug container).

## Configuration

Create a JSON config file:

```json
{
    "namespace": "default",
    "node": "aks-gpunp-12730235-vmss000000",
    "gpus": ["0", "1", "2", "3", "4", "5", "6", "7"],
    "nics": ["mlx5_0", "mlx5_1", "mlx5_2", "mlx5_3", "mlx5_4", "mlx5_5", "mlx5_6", "mlx5_7"],
    "gpu_type": "cuda",
    "num_iters": 5000,
    "msg_size": 2
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `namespace` | Kubernetes namespace | required |
| `node` | Node name (pod derived as `networking-debug-pod-<node>`) | one of `node`/`pod` |
| `pod` | Pod name directly (use when pod name is non-standard) | one of `node`/`pod` |
| `gpus` | GPU indices to test | required |
| `nics` | HCA device names (e.g. `mlx5_0`) | required |
| `gpu_type` | `"cuda"` or `"rocm"` | `"cuda"` |
| `rdma_op` | Must be `"read"` for GPU tests | `"read"` |
| `num_iters` | Latency test iterations | `5000` |
| `msg_size` | Message size in bytes | `2` |
| `localhost_target` | Client connection target | `127.0.0.1` |
| `server_startup_delay` | Seconds to wait after starting server | `2.0` |

Use **`node`** when the pod follows the `deploy_pod_to_node.sh` naming convention. Use **`pod`** when targeting an existing pod by exact name (e.g. `networking-debug-pod-aks-gpunp-12730235-vmss000000`).

## Usage

```bash
cd intra_node_tests/gpu-nic-latency

# Human-readable matrix output
uv run ./gpu_nic_latency.py 8gpu-8nic-aks-h100.json

# JSON output (for scripting / analysis)
uv run ./gpu_nic_latency.py --json 8gpu-8nic-aks-h100.json
```

## Output

Human mode prints two sections:

1. **Median Latency** — one matrix (`t_typical`)
2. **Tail Latency** — separate matrices for p99 and p99.9

```bash
uv run ./gpu_nic_latency.py 8gpu-8nic-aks-h100.json

# Median only
uv run ./gpu_nic_latency.py --no-tail 8gpu-8nic-aks-h100.json
```

JSON mode (`--json`) includes:

- `matrix_median_usec` — median matrix
- `matrices_tail_usec` — `{ "p99": {...}, "p99_9": {...} }`
- `matrix_usec` — median matrix alias (backward compatible)
- `results` — per-pair details including `p99_usec`, `p99_9_usec`, min/max/avg/stdev
- `summary` — success/failure counts

Exit code: `0` if all pairs succeed, `1` if any fail.

## How It Works

1. Resolve pod name from `node` or `pod` config field
2. Verify the pod is Running
3. Start **all servers in parallel** (one per pair, unique port)
4. Run **clients serially** against `127.0.0.1`
5. Print latency matrix (median + tail)
