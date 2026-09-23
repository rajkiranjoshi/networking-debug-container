# Intra-Node Testing Tools

Automated test scripts for validating intra-host GPU–NIC topology and performance on a single node.

## Prerequisites

- A `networking-debug-pod` already deployed on the target node (`deploy_pod_to_node.sh`)
- [uv](https://github.com/astral-sh/uv) for Python scripts
- `kubectl` access to the cluster

## Available Tests

### GPU–NIC Latency Matrix (`gpu-nic-latency/`)

Measures RDMA latency between each GPU and each NIC on the same node using localhost loopback (`ib_read_lat` server + client on the same pod/NIC).

```bash
cd gpu-nic-latency
uv run ./gpu_nic_latency.py 8gpu-8nic-aks-h100.json
```

See [gpu-nic-latency/README.md](gpu-nic-latency/README.md) for configuration details.

### GPU–NIC Bandwidth Matrix (`gpu-nic-bandwidth/`)

Measures RDMA bandwidth between each GPU and each NIC on the same node using localhost loopback (`ib_write_bw` server + client on the same pod/NIC).

```bash
cd gpu-nic-bandwidth
uv run ./gpu_nic_bandwidth.py 8gpu-8nic-aks-h100.json
```

See [gpu-nic-bandwidth/README.md](gpu-nic-bandwidth/README.md) for configuration details.
