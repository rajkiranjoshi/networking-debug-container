# Remote handoff: Dell B200 BlueField-3 firmware update

Read this file first after cloning the repository. It captures the decisions and
verified state needed to continue without the original chat session.

## Current state

- Planning and guarded scripts are complete.
- No firmware installation has been executed.
- The derived maintenance image has not yet been built because the original
  macOS workstation had no running Docker/Podman daemon.
- The next action is to build and inspect the image on an x86_64 Docker host.
- Do not run an installer merely as part of validating the build.

Before cloning remotely, ensure local `main` is pushed. At handoff creation it
was 10 commits ahead of `origin/main`; an unpushed commit cannot be recovered by
cloning.

Repository:
`https://github.com/rajkiranjoshi/network-debug-container.git`

## Objective

Update the full DOCA 3.5 BF-Bundle on 20 BlueField-3 B3140H SuperNICs, 10 on
each of `dell-b200-01` and `dell-b200-02`, while leaving all other adapters
untouched. The historical problem to address occurred in NIC mode with eight
VFs per PF: the first same-rail pod pair reached line rate, while a second
simultaneous pair using another VF fell below 1 Mbps or timed out.

The complete inventory and reasoning are in
[`bf3-fw-update-plan-dell-b200.md`](./bf3-fw-update-plan-dell-b200.md). The
operator procedure is in
[`bf3-fw-update-steps-dell-b200.md`](./bf3-fw-update-steps-dell-b200.md).

## Fixed device and artifact identity

| Item | Required value |
|---|---|
| Target count | 10 per node, 20 total |
| Product | NVIDIA BlueField-3 B3140H E-series HHHL SuperNIC |
| OPN | `900-9D3D4-00EN-HA0_Ax` |
| PSID | `MT_0000001069` |
| Current NIC firmware | `32.43.1014` |
| Target NIC firmware | `32.50.1002` |
| Required final mode | NIC mode: `INTERNAL_CPU_OFFLOAD_ENGINE=DISABLED(1)` |
| Bundle | `bf-bundle-3.5.0-89_26.07_ubuntu-24.04_64k_prod.bfb` |
| Bundle SHA-256 | `823958b7fcf9f9354a640a88f0e3b06807204209fa9201c46b6e285202aee243` |

The BFB is intentionally gitignored and was originally in `~/Downloads` on the
macOS workstation. Transfer it separately if the remote system will run
`stage-bfb.sh`, then verify the hash. Never commit the BFB or `bf.cfg`.

The scripts permit only the targets in [`config/targets.tsv`](./config/targets.tsv).
Hard exclusions include both B3220 DPUs, the B3220 frontend adapter on each
node, and the internal four-port ConnectX-7. Never replace per-RShim installs
with a global or PSID-wide installer invocation.

## Confirmed cluster state on 2026-09-23

- OpenShift 4.22.9.
- Both nodes run RHCOS `9.8.20260804-2` with kernel
  `5.14.0-687.35.1.el9_8.x86_64`.
- Only the RHCOS in-tree `mlx5_core`/`mlx5_ib` drivers are active.
- NVIDIA Network Operator is not installed.
- OpenShift SR-IOV Network Operator is not installed.
- No VFs are configured.
- Dell iDRAC console and power control are available for both nodes.
- The current OpenShift user can create Pods and use the `privileged` SCC.

No custom service account is required because this workflow creates Pods
directly under the current user's SCC authorization. Kubernetes still assigns
the namespace's default account, but the Pod disables token mounting with
`automountServiceAccountToken: false`.

## Maintenance image design

[`Containerfile`](./Containerfile) derives from the existing networking debug
image so the maintenance Pod retains RDMA, perftest, CUDA/ROCm, MFT, and other
diagnostic tools. The base corresponding to
`quay.io/rajjoshi/networking-debug-container:latest` was pinned as:

```text
quay.io/rajjoshi/networking-debug-container@sha256:31488362bffe534d77de8b7ee36d4ef708b643a6f75bee254e017cd92fe6fc71
```

The derivative explicitly installs these DOCA 3.5 versions:

- `rshim=2.8.5-1`
- `mft=4.37.0-154`
- `doca-installer=2.0.3-1`

The versions and repository key URL were verified against NVIDIA's DOCA 3.5
Ubuntu 24.04 repository. `--allow-downgrades` is deliberate: it ensures the
pinned DOCA MFT replaces any different MFT inherited from the debug image.
These are container userspace packages; nothing installs a vendor driver,
OFED, or DKMS onto RHCOS.

Do not use the raw networking-debug image for firmware installation. Do not use
a mutable image tag in the maintenance Pod.

## Build and publish on the remote x86_64 Docker host

```bash
git clone https://github.com/rajkiranjoshi/network-debug-container.git
cd network-debug-container/bf3-fw-update

export IMAGE_TAG=REGISTRY/PROJECT/bf3-fw-maintenance:doca-3.5.0
scripts/build-image.sh "$IMAGE_TAG"

docker run --rm "$IMAGE_TAG" \
  dpkg-query -W rshim mft doca-installer
docker run --rm "$IMAGE_TAG" bash -lc \
  'command -v rshim bfb-install doca-installer mst flint mlxconfig ib_write_bw'

docker push "$IMAGE_TAG"
docker buildx imagetools inspect "$IMAGE_TAG"
```

Expected package versions are exactly `2.8.5-1`, `4.37.0-154`, and `2.0.3-1`.
Record the pushed `sha256:` manifest digest and construct:

```bash
export IMAGE='REGISTRY/PROJECT/bf3-fw-maintenance@sha256:DIGEST'
```

The deployment helper rejects mutable tags. If the remote host is only the
image builder, return the digest to the OpenShift operator workstation. If it
will also run the workflow, it additionally needs `oc`, a valid kubeconfig,
registry access, and the separately transferred BFB.

## Workflow mechanics and safety

- Work on one node and one device at a time.
- Keep both iDRAC sessions available throughout the maintenance window.
- Drain and cordon before creating the maintenance Pod.
- [`scripts/deploy_pod_to_node.sh`](./scripts/deploy_pod_to_node.sh) uses the
  hostname `nodeSelector`, tolerates the cordon's unschedulable taint, and
  verifies the resulting `.spec.nodeName`.
- The Pod is privileged and host-networked, mounts host `/dev`, `/sys`, and
  `/lib/modules`, and stores persistent work under
  `/var/tmp/bf3-fw-update` on the host.
- RShim starts without force takeover. Never add `-F` without a separate review.
- Every write requires the exact confirmation `--confirm NODE/PF_BDF`.
- Every write rechecks the target table, live RShim mapping, PSID, OPN, mode,
  interface, bundle hash, and `sriov_numvfs=0`.
- `doca-installer` is the default writer. `--legacy-bfb-install` is a reviewed
  fallback only; never run both concurrently.
- Exit 20 means the installer requested a cold host power cycle. Exit 21 means
  target firmware was not active. Stop, archive logs, and use graceful shutdown
  plus iDRAC cold power control.
- Post-update verification requires all 10 targets to report firmware
  `32.50.1002`, NIC mode, `mlx5_core`, PCIe 32 GT/s x16, and zero VFs.

The first canary sequence, after the image is published and OpenShift access is
available, is:

```bash
cd bf3-fw-update
export NODE=dell-b200-01
export PF=0000:18:00.0
export BFB=/secure/path/bf-bundle-3.5.0-89_26.07_ubuntu-24.04_64k_prod.bfb

scripts/verify-cluster.sh "$NODE" --confirm-idrac
scripts/drain-node.sh "$NODE" --confirm-drain
scripts/deploy_pod_to_node.sh "$NODE" "$IMAGE"
scripts/stage-bfb.sh "$NODE" "$BFB"
scripts/start-rshim.sh "$NODE"
scripts/inventory.sh "$NODE"
scripts/preflight-device.sh "$NODE" "$PF"
scripts/install-device.sh "$NODE" "$PF" --confirm "$NODE/$PF"
```

Do not execute this canary merely to validate the remote image build. Firmware
installation requires a separately declared maintenance window.

## Validation already completed

- All shell scripts pass `bash -n`.
- All intended scripts have executable mode.
- The target table contains exactly 10 approved rows per node.
- Non-target PF rejection and pinned-constant behavior were tested locally.
- The rendered Pod manifest passed an OpenShift client dry-run.
- The pinned debug base digest was resolved from Quay.
- The DOCA repository contains the exact pinned package versions.
- A full container build remains pending on the remote Docker host.

## Deferred acceptance test

The firmware window cannot reproduce the original problem because this cluster
currently has no Network Operator and no VFs. After the NVIDIA Network Operator
and SR-IOV configuration are installed, configure `numVfs: 8` and repeat the
two simultaneous same-rail pod-pair `ib_write_bw` test documented in the plan.

## Suggested re-initialization prompt

```text
Read bf3-fw-update/REMOTE-HANDOFF.md and the linked update-steps document.
Continue from the remote x86_64 image-build stage. First inspect repository
state and validate/build the maintenance image only. Do not access the cluster,
drain nodes, or execute any firmware writer unless I explicitly authorize the
maintenance operation.
```
