# RoCE Multi-NIC GDR Two-Node Validation Report

**Date:** 2026-07-23  
**Cluster:** `api-rits-roce-fmaas-res-ibm-com:6443`  
**Namespace:** `ecrncevi-dev-p12w4d3w4`

## 1. Setup

| Item | Value |
|------|-------|
| Nodes | `rits-roce-z6lst-worker-h100-3-gdr-ccthw`, `rits-roce-z6lst-worker-h100-3-gdr-ds5tz` |
| Pods | `networking-debug-pod-…-ccthw`, `networking-debug-pod-…-ds5tz` |
| CNI | Multus `deepep-ll-port-1` … `deepep-ll-port-8` (host-device + DHCP + **`sbr-custom`** + tuning MTU 9000) |
| hostNetwork | **false** |
| Resources | `nvidia.com/gpu: 8`, `nvidia.com/roce_gdr: 8` |
| Caps | `IPC_LOCK`, `NET_RAW` |
| Image | `quay.io/rajjoshi/networking-debug-container:latest` |

Secondary interfaces: `net1` … `net8` → `10.0.0.0/16` … `10.7.0.0/16`.

### Source-based routing (verified in-pod)

```
from 10.0.0.70 lookup 100  →  default via 10.0.0.1 dev net1
from 10.1.0.70 lookup 101  →  default via 10.1.0.1 dev net2
...
from 10.7.0.70 lookup 107  →  default via 10.7.0.1 dev net8
```

(Same pattern on ds5tz with `.41` addresses.)

## 2. Multus IPs (by iface / HCA / subnet)

| GPU | HCA | Iface | Subnet | ccthw IP | ds5tz IP |
|-----|-----|-------|--------|----------|----------|
| 0 | mlx5_8 | net1 | 10.0.0.0/16 | 10.0.0.70 | 10.0.0.41 |
| 1 | mlx5_7 | net2 | 10.1.0.0/16 | 10.1.0.70 | 10.1.0.41 |
| 2 | mlx5_6 | net3 | 10.2.0.0/16 | 10.2.0.70 | 10.2.0.41 |
| 3 | mlx5_5 | net4 | 10.3.0.0/16 | 10.3.0.70 | 10.3.0.41 |
| 4 | mlx5_4 | net5 | 10.4.0.0/16 | 10.4.0.70 | 10.4.0.41 |
| 5 | mlx5_3 | net6 | 10.5.0.0/16 | 10.5.0.70 | 10.5.0.41 |
| 6 | mlx5_2 | net7 | 10.6.0.0/16 | 10.6.0.70 | 10.6.0.41 |
| 7 | mlx5_1 | net8 | 10.7.0.0/16 | 10.7.0.70 | 10.7.0.41 |

## 3. PCIe topology / GPU–NIC pairing

From `nvidia-smi topo -m` (PIX = same PCIe bridge):

| GPU | Closest NIC | HCA | Role |
|-----|-------------|-----|------|
| GPU0…GPU7 | NIC8…NIC1 | **mlx5_8…mlx5_1** | RoCE GDR fabric |
| — | NIC0 | **mlx5_0** | Control-plane NIC; SYS to all GPUs (`0000:03:00.0` / `enp3s0`) |

**Hypothesis confirmed:** GPU0→mlx5_8 … GPU7→mlx5_1; mlx5_0 is not a GPU-adjacent RoCE fabric NIC.

## 4. Pingmesh

Config: `reports/rits-roce/configs/pingmesh-rits-roce-2node.json` (`net1`…`net8`)  
Log: `reports/rits-roce/pingmesh-rits-roce-2node-sbr.log`

| Metric | Result |
|--------|--------|
| Full 8×8 mesh | **64/64 (100%)** |
| Same-subnet | pass |
| Cross-subnet | pass (via SBR gateways) |
| Runtime | about 4 s |

## 5. Multi-NIC GDR `ib_write_bw`

Config: `reports/rits-roce/configs/8gpu-pairs-rits-roce.json`  
Raw JSON: `reports/rits-roce/rits-roce-ib-write-bw-sbr.json`

| Parameter | Value |
|-----------|-------|
| Op | RDMA WRITE + `--use_cuda` (GDR) |
| Msg size | 1 MiB |
| QPs | **8** |
| Duration | 60 s |
| Direction | uni-directional (ccthw → ds5tz) |

| Aggregate | Value |
|-----------|-------|
| Successful pairs | **8/8** |
| Per-NIC avg | **386.04 Gbps** |
| Total avg | **3088.32 Gbps** |
| Wall time | 79.07 s |

## 6. iperf3 TCP — pod network (OVN eth0)

Path: pod `eth0` only (not RoCE).  
Client: ccthw `10.130.16.67` → server: ds5tz `10.129.10.62`  
Raw JSON: `reports/rits-roce/iperf3-pod-network-control-plane.json`

| Parameter | Value |
|-----------|-------|
| Tool | iperf3 3.16 |
| Protocol | TCP |
| Parallel streams | **-P 10** |
| Duration | 30 s |

| Metric | Value |
|--------|-------|
| Sender | **67.318 Gbps** |
| Receiver | **67.309 Gbps** |
| Retransmits | 31066 |

## 7. Control-plane NIC link speed + hostNetwork TCP push

Probe pods: `hn-mtu-iperf-*` — **hostNetwork: true**, no Multus/SBR, no GPU, no RDMA. Path: `br-ex` node IPs `10.241.129.71` → `10.241.129.42`.

### Hardware

| Item | Value |
|------|-------|
| Physical NIC | **`enp3s0`** (`mlx5_0`, PCI `0000:03:00.0`) |
| Link speed | **200 Gbps** Full Duplex |
| enp3s0 MTU | **9000** |
| br-ex MTU | **1500** (OVN-managed; resets to 1500 within about 250ms if raised) |
| Host path | `enp3s0` → OVS → **`br-ex`** |

Jumbo frames on `br-ex` could not be held for testing — OVN reverts MTU to 1500. Physical NIC already supports 9000 / 200G.

### iperf3 TCP push (MTU 1500, `-w 4M`, 30s)

| Streams | Sender | Receiver | Retransmits | Raw JSON |
|---------|--------|----------|-------------|----------|
| **-P 32** | **161.351 Gbps** | **161.300 Gbps** | 85521 | `reports/rits-roce/iperf3-hostnetwork-mtu1500-p32.json` |
| -P 64 | 155.970 Gbps | 155.873 Gbps | 84485 | `reports/rits-roce/iperf3-hostnetwork-mtu1500-p64.json` |
| -P 128 | 151.107 Gbps | 150.909 Gbps | 120298 | `reports/rits-roce/iperf3-hostnetwork-mtu1500-p128.json` |

Best observed: **about 161 Gbps** at 32 streams (vs earlier -P 10 at about 114 Gbps). Link is 200G; remaining gap is likely MTU 1500 / stack overhead, not link rate.

## 8. Notes

1. Debug pods on ccthw/ds5tz still hold 8 GPU + 8 `roce_gdr` each — delete when finished.
2. Pod OVN eth0 TCP (about 67 Gbps) < hostNetwork br-ex (about 161 Gbps peak) < physical link (**200G**).
3. To use jumbo on the control plane, raise the cluster/OVN gateway MTU (not just `ip link set br-ex`).
