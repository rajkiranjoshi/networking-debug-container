# Networking Debug Container

A comprehensive Docker container for debugging and testing high-performance networking, RDMA (Remote Direct Memory Access), and GPU-direct capabilities. Built with support for both NVIDIA (CUDA) and AMD (ROCm) GPUs.

## Features

- **RDMA/InfiniBand Tools**: Complete MLNX OFED toolkit including `ibv_devinfo`, `ibstat`, `perftest` suite
- **GPU Support**: Pre-compiled perftest binaries with both CUDA and ROCm support
- **Networking Utilities**: `ping`, `iperf3`, `netstat`, `tcpdump`, `ethtool`, and more
- **Inter-node Test Scripts**: Python and Bash scripts for automated connectivity and bandwidth testing

## Container Image

The pre-built container is available at:
```
quay.io/rajjoshi/networking-debug-container:latest
```

## Building the Image Locally

```bash
./build_docker_image.sh
```

This builds a multi-stage Docker image (~4 GB) with:
- CUDA 12.8 runtime libraries
- ROCm 6.3 runtime libraries  
- MLNX OFED tools and libraries
- perftest binaries compiled with CUDA + ROCm support

## Deploying to Kubernetes

### Prerequisites

- Kubernetes cluster with RDMA-capable nodes
- For NVIDIA GPUs: [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin) installed
- For AMD GPUs: [AMD GPU Device Plugin](https://github.com/ROCm/k8s-device-plugin) installed

### Deploy Pod to a Node

Use the deployment script to deploy the debug pod to a specific node:

#### Without GPUs

```bash
./deploy_pod_to_node.sh <node-name> --namespace <namespace>

# Example
./deploy_pod_to_node.sh worker-node-1 --namespace my-network-debug
```

#### With NVIDIA GPUs

```bash
./deploy_pod_to_node.sh <node-name> --namespace <namespace> --request-nvidia-gpus <count>

# Example: Request 8 NVIDIA GPUs
./deploy_pod_to_node.sh gpu-node-1 --namespace my-network-debug --request-nvidia-gpus 8
```

#### With AMD GPUs

```bash
./deploy_pod_to_node.sh <node-name> --namespace <namespace> --request-amd-gpus <count>

# Example: Request 8 AMD GPUs
./deploy_pod_to_node.sh gpu-node-1 --namespace my-network-debug --request-amd-gpus 8
```

### Pod Naming Convention

The pod will be named `networking-debug-pod-<node-name>`. For example:
- Node `10.0.65.77` → Pod `networking-debug-pod-10.0.65.77`

### Access the Pod

```bash
kubectl exec -it networking-debug-pod-<node-name> -n <namespace> -- bash
```

## Running with Docker

### Basic Usage (No GPU)

```bash
docker run --rm -it \
    --network=host \
    --privileged \
    -v /dev/infiniband:/dev/infiniband \
    quay.io/rajjoshi/networking-debug-container:latest
```

### With NVIDIA GPUs

```bash
docker run --rm -it \
    --network=host \
    --privileged \
    --gpus=all \
    -v /dev/infiniband:/dev/infiniband \
    quay.io/rajjoshi/networking-debug-container:latest
```

Or request specific GPUs:
```bash
docker run --rm -it \
    --network=host \
    --privileged \
    --gpus='"device=0,1"' \
    -v /dev/infiniband:/dev/infiniband \
    quay.io/rajjoshi/networking-debug-container:latest
```

Verify NVIDIA GPUs inside container:
```bash
nvidia-smi
```

### With AMD GPUs

AMD GPUs require access to `/dev/kfd` (Kernel Fusion Driver) and `/dev/dri` (Direct Rendering Infrastructure):

```bash
docker run --rm -it \
    --network=host \
    --privileged \
    --device=/dev/kfd \
    --device=/dev/dri \
    -v /dev/infiniband:/dev/infiniband \
    --group-add video \
    --group-add render \
    quay.io/rajjoshi/networking-debug-container:latest
```

Verify AMD GPUs inside container:
```bash
amd-smi list
# or
rocm-smi
```

### GPU-Direct RDMA Testing

Once inside the container, test GPU-direct bandwidth:

```bash
# NVIDIA GPU (server)
ib_write_bw -d mlx5_0 --use_cuda=0

# NVIDIA GPU (client)
ib_write_bw -d mlx5_0 --use_cuda=0 <server_ip>

# AMD GPU (server)
ib_write_bw -d mlx5_0 --use_rocm=0

# AMD GPU (client)  
ib_write_bw -d mlx5_0 --use_rocm=0 <server_ip>
```

## Inter-Node Testing Tools

The `inter_node_tests/` directory contains automated test scripts for validating connectivity and measuring RDMA bandwidth across nodes. See [inter_node_tests/README.md](inter_node_tests/README.md) for details.

Available tests:
- **Pingmesh**: Network connectivity validation between all NICs
- **Single-NIC Bandwidth**: `ib_write_bw` tests on a single NIC pair
- **Multi-NIC Bandwidth**: Simultaneous `ib_write_bw` across multiple NIC pairs

## Utility Scripts

The `scripts/` directory contains helpful utilities for debugging network and RDMA configurations. See [scripts/README.md](scripts/README.md) for details.

## Common Commands

Inside the container:

```bash
# List InfiniBand devices
ibv_devinfo

# Show InfiniBand status
ibstat

# List network interfaces with IPs
ip -br addr

# Check HCA firmware
mstflint -d mlx5_0 q

# Run bandwidth test
ib_write_bw -d mlx5_0 -s 1048576 -q 4 -n 5000 --report_gbits
```

## Troubleshooting

### "No IB devices found"
- Ensure RDMA drivers are loaded on the host
- Check that `/dev/infiniband` is mounted
- Verify the container is running with `--privileged`

### GPU not detected
- NVIDIA: Ensure `nvidia-container-toolkit` is installed and `--gpus` flag is used
- AMD: Ensure `/dev/kfd` and `/dev/dri` are accessible

### Permission denied on /dev/infiniband
- Run with `--privileged` flag
- Or add appropriate capabilities: `--cap-add=IPC_LOCK --cap-add=NET_RAW`

## License

MIT License
