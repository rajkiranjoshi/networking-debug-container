# Utility Scripts

Helper scripts for debugging and inspecting network and RDMA configurations.

## Scripts

### `iface_to_hca_mapping.sh`

Maps network interfaces to their corresponding HCA (Host Channel Adapter) devices.

```bash
./iface_to_hca_mapping.sh
```

Example output:
```
rdma0 -> mlx5_0
rdma1 -> mlx5_2
rdma2 -> mlx5_3
...
```

### `get_ifaces_with_ip_addr.sh`

Lists all network interfaces that have an IPv4 address assigned.

```bash
./get_ifaces_with_ip_addr.sh
```

Example output:
```
eth0: 10.0.65.77
rdma0: 10.224.2.77
rdma1: 10.224.18.77
...
```

### `map_vfs_to_pfs.sh`

Maps SR-IOV Virtual Functions (VFs) to their parent Physical Functions (PFs).

```bash
./map_vfs_to_pfs.sh
```

Useful for debugging SR-IOV configurations and understanding VF-to-PF relationships.

### `check_iommu_pci_acs.sh`

Checks IOMMU and PCI ACS (Access Control Services) configuration on the host.

```bash
./check_iommu_pci_acs.sh
```

Useful for diagnosing GPU-direct RDMA and device passthrough issues.

## Usage

These scripts are copied to `/root/scripts/` inside the container. Run them from within a deployed pod:

```bash
kubectl exec -it networking-debug-pod-<node> -n <namespace> -- bash
cd /root/scripts
./iface_to_hca_mapping.sh
```
