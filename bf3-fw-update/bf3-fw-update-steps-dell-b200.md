# Manual BF3 firmware update: Dell B200 nodes

Status: planned, not executed. This runbook updates one device at a time and one
node at a time. The detailed inventory, package analysis, and firmware rationale
remain in [`bf3-fw-update-plan-dell-b200.md`](./bf3-fw-update-plan-dell-b200.md).

## Scope and fixed safety rules

- Nodes: `dell-b200-01` and `dell-b200-02`
- Targets: 10 B3140H SuperNICs per node (20 total)
- Required OPN: `900-9D3D4-00EN-HA0_Ax`
- Required PSID: `MT_0000001069`
- Expected transition: NIC firmware `32.43.1014` to `32.50.1002`
- Required final mode: NIC mode,
  `INTERNAL_CPU_OFFLOAD_ENGINE=DISABLED(1)`
- Bundle: `bf-bundle-3.5.0-89_26.07_ubuntu-24.04_64k_prod.bfb`
- Expected SHA-256:
  `823958b7fcf9f9354a640a88f0e3b06807204209fa9201c46b6e285202aee243`

The scripts reject devices outside [`config/targets.tsv`](./config/targets.tsv),
including the B3220 frontend adapters and the internal four-port ConnectX-7.
They also recheck the live RShim-to-PCI mapping, PSID, OPN, NIC mode, BFB hash,
interface, and zero-VF state before every write. Do not replace the per-device
commands with a global or PSID-wide installation.

## Verified environment

The OpenShift API was checked on 2026-09-23:

| Item | State |
|---|---|
| OpenShift | 4.22.9 |
| Host OS | RHCOS `9.8.20260804-2` on both nodes |
| Kernel | `5.14.0-687.35.1.el9_8.x86_64` |
| Host networking | In-tree `mlx5_core`/`mlx5_ib`; no vendor driver change |
| NVIDIA Network Operator | Not installed |
| OpenShift SR-IOV Network Operator | Not installed |
| Configured VFs | None |
| Recovery path | Dell iDRAC BMC access is available for both nodes |

The temporary image extends the repository's existing Ubuntu 24.04 networking
debug image, preserving its RDMA, perftest, CUDA/ROCm, and diagnostic tools. It
adds and pins the host-side firmware tools `rshim=2.8.5-1`, `mft=4.37.0-154`,
and `doca-installer=2.0.3-1` from the DOCA 3.5 repository. These are container
userspace packages; the workflow does not install OFED, DKMS, or a vendor mlx5
driver on RHCOS.

This derivative is larger than a firmware-only Ubuntu image and the debug base
contains packages originally sourced from a floating MLNX_OFED repository. To
keep the update reproducible, the `Containerfile` pins both the debug-image
digest and the firmware-tool versions; `--allow-downgrades` ensures the required
DOCA 3.5 MFT wins if the base contains a different MFT version. Do not use the
raw networking-debug image for a firmware write because it lacks the pinned
RShim/DOCA Installer layer and the workflow's embedded verification helpers.

## Why there is no dedicated service account

A custom service account is unnecessary for this operator-driven workflow.
The current user was verified to be able to create Pods and `use` the
`privileged` SCC. Because the manifest creates a Pod directly, SCC admission can
authorize that creating user.

Kubernetes still assigns the namespace's `default` service account when
`serviceAccountName` is omitted, but the Pod does not rely on that account for
privilege or API access. The template sets `automountServiceAccountToken: false`.
A dedicated service account and SCC grant would become useful only if this were
delegated to a controller, Job, CI system, or another operator identity.

## Files

| Path | Purpose |
|---|---|
| [`Containerfile`](./Containerfile) | Extends the pinned networking-debug image with DOCA 3.5 firmware tools |
| [`config.env`](./config.env) | Pinned firmware, OPN, PSID, mode, and count |
| [`config/targets.tsv`](./config/targets.tsv) | Approved PF, management BDF, and interface mapping |
| [`manifests/maintenance-pod.yaml.tpl`](./manifests/maintenance-pod.yaml.tpl) | Privileged, host-networked Pod template |
| [`scripts/`](./scripts/) | Workstation-side guarded workflow |
| [`container/`](./container/) | Read-only inventory and verification helpers run in the Pod |
| `artifacts/<node>/` | Generated inventories, verification output, and copied logs; gitignored |

Run all commands below from this directory:

```bash
cd bf3-fw-update
```

## 1. Build and publish the maintenance image

The base corresponding to `quay.io/rajjoshi/networking-debug-container:latest`
on 2026-09-23 is pinned as
`sha256:31488362bffe534d77de8b7ee36d4ef708b643a6f75bee254e017cd92fe6fc71`.
Do not replace it with a mutable tag during the maintenance window. Build from
a machine that can push to a registry accessible by the cluster:

```bash
scripts/build-image.sh REGISTRY/PROJECT/bf3-fw-maintenance:doca-3.5.0
docker push REGISTRY/PROJECT/bf3-fw-maintenance:doca-3.5.0
```

The build helper defaults to Docker, matching this repository. Set
`CONTAINER_ENGINE=podman` if preferred.

Resolve the pushed image to an immutable digest. The Pod deployment script
rejects tags:

```bash
export IMAGE='REGISTRY/PROJECT/bf3-fw-maintenance@sha256:DIGEST'
export BFB="$HOME/Downloads/bf-bundle-3.5.0-89_26.07_ubuntu-24.04_64k_prod.bfb"
```

## 2. Update the first node and canary device

Keep an operator logged into both iDRACs for the complete window. Start with
`dell-b200-01` and its first approved PF:

```bash
export NODE=dell-b200-01
export PF=0000:18:00.0

scripts/verify-cluster.sh "$NODE" --confirm-idrac
scripts/drain-node.sh "$NODE" --confirm-drain
scripts/deploy_pod_to_node.sh "$NODE" "$IMAGE"
scripts/stage-bfb.sh "$NODE" "$BFB"
scripts/start-rshim.sh "$NODE"
scripts/inventory.sh "$NODE"
scripts/preflight-device.sh "$NODE" "$PF"
scripts/install-device.sh "$NODE" "$PF" --confirm "$NODE/$PF"
```

`doca-installer` is the default writer. The direct legacy path is available
only for an explicitly reviewed fallback:

```bash
scripts/install-device.sh "$NODE" "$PF" \
  --confirm "$NODE/$PF" --legacy-bfb-install
```

Never run the two writers concurrently or retry one while the other is active.
The installer log path is recorded in `/work/last-install-log`.

### Optional BMC/CEC firmware configuration

The full BF-Bundle updates the BlueField platform and Arm OS. BMC/CEC updates
require a separately approved config containing BMC credentials. Do not commit
that file, bake it into the image, or put its values in shell history. If it is
in scope, place the config at `/work/bf.cfg` through an approved secret-handling
method and add:

```bash
--config-remote /work/bf.cfg
```

to the `install-device.sh` invocation. Log archival explicitly excludes
`bf.cfg` and all BFB files.

## 3. Handle an activation power cycle

Exit code `20` means the installer explicitly requested a host power cycle.
Exit code `21` means the device did not report target firmware after the live
activation attempt. For either result:

1. Do not continue to another device.
2. Archive the available logs.
3. Gracefully shut down the node, then perform the required cold power cycle
   through iDRAC. A Kubernetes reboot is only a warm reboot.
4. Wait for RHCOS and the kubelet to return.
5. Recreate the maintenance Pod, restart RShim, rerun inventory, and repeat the
   device preflight before making any further write.

Example pre-cycle archive:

```bash
scripts/archive-logs.sh "$NODE" "artifacts/$NODE"
oc delete pod -n bf3-fw-maintenance "bf3-fw-maintenance-$NODE" --wait=true
```

Do not use `finish-node.sh` at this point because that script also uncordons the
node. The host directory `/var/tmp/bf3-fw-update` is retained across Pod
recreation and is intentionally not deleted automatically.

## 4. Update the remaining devices

After the canary passes, run the same explicit preflight and confirmed install
for each remaining PF listed for that node in `config/targets.tsv`. Deliberately
there is no automatic install loop. Example:

```bash
export PF=0000:1a:00.0
scripts/preflight-device.sh "$NODE" "$PF"
scripts/install-device.sh "$NODE" "$PF" --confirm "$NODE/$PF"
```

If the Pod or node was restarted, always run these first:

```bash
scripts/start-rshim.sh "$NODE"
scripts/inventory.sh "$NODE"
```

## 5. Verify and return the node to service

Only after all 10 approved targets on the node report the target firmware:

```bash
scripts/verify-node.sh "$NODE"
scripts/archive-logs.sh "$NODE" "artifacts/$NODE"
scripts/finish-node.sh "$NODE" --confirm-return-to-service
```

Confirm the node, MachineConfigPool, and cluster operators remain healthy.
Then repeat sections 2–5 with `NODE=dell-b200-02`. Do not work on both nodes
simultaneously.

After both nodes pass and their logs are archived:

```bash
scripts/cleanup-namespace.sh --confirm-delete-namespace
```

The cleanup intentionally retains each host's `/var/tmp/bf3-fw-update` for
manual review and later removal.

## 6. Deferred SR-IOV acceptance test

This new cluster has no Network Operator and no VFs, so the historical defect
cannot be reproduced during the firmware-only window. After the NVIDIA Network
Operator/SR-IOV configuration is installed, repeat the exact two-pod-pair test:

1. Configure each target PF with `numVfs: 8`.
2. Run the first one-VF-per-PF pod pair on the same rail and confirm line rate.
3. Keep it running, create a second equivalent pair, and run `ib_write_bw`.
4. Require the second pair to avoid the prior sub-1-Mbps/timeout failure while
   confirming that the first pair remains healthy.

## References

- [NVIDIA BF-Bundle installation and upgrade](https://docs.nvidia.com/doca/sdk/bf-bundle-installation-and-upgrade/)
- [NVIDIA DOCA 3.5 installation guide](https://networking-docs.nvidia.com/doca/archive/3-5-0/doca-installation-guide-for-linux)
- [NVIDIA DOCA 3.5 general support and component versions](https://networking-docs.nvidia.com/doca/archive/3-5-0/general-support)
