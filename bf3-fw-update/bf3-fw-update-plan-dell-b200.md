# BlueField-3 firmware update plan: Dell B200 nodes

Inventory collected 2026-09-22 from the two privileged debug pods and
correlated with the four `intrahost-topo` PCIe diagrams.

## Package decision

**Preferred package:** full BF-Bundle
`bf-bundle-3.5.0-89_26.07_ubuntu-24.04_64k_prod.bfb`, subject to the execution
gates below. No firmware has been written as part of this investigation.

The full bundle is preferred because it installs the BlueField software stack
as a tested combination rather than replacing only selected firmware
components. This matches the prior B3220 operational experience: a standalone
ConnectX-7/NIC firmware change left components out of alignment, while a full
SoC bundle produced a working combination.

This choice has a major operational consequence: a full BF-Bundle is also an
Arm-side OS installation. It overwrites the BlueField Arm boot partition and
may reset local configuration. It must be treated as a BlueField reimage and
platform update, not as an ordinary NIC firmware flash.

**This consequence is accepted for the 20 B3140H targets (10 per node).** Their
intended end state is NIC mode, using the integrated ConnectX-7 as a conventional
host-owned adapter rather than running Arm-side DPU services or persistent
workloads. Preserving an existing Arm userspace is therefore not a deployment
requirement. The preflight should still confirm that no unexpected Arm-side
state, provisioning, or platform integration depends on the current image.

## Upgrade motivation and release-note assessment

### Observed SR-IOV/RDMA failure

The update is intended to address a reproducible failure on B3140H SuperNICs
with OPN `900-9D3D4-00EN-HA0_Ax`, PSID `MT_0000001069`, firmware
`32.43.1014`, and BlueField configured in NIC mode:

1. Configure the SR-IOV Network Operator with `numVfs: 8`.
2. Deploy one pod per node, assigning one VF from the rail-1 PF to each pod.
3. Run `ib_write_bw` rail 1 to rail 1; it reaches line rate.
4. Leave the original pods deployed and deploy a second pod per node, again
   assigning one VF from the same PF to each new pod.
5. Run the same rail-1 `ib_write_bw` test between the second pod pair; observed
   performance is below 1 Mbps or the operation times out.

This pattern is consistent with a device or driver resource/state problem
exposed by subsequent VF/QP use. It is not a basic link, cable, or first-VF
connectivity failure.

### Is DOCA 3.5.0 current?

As checked on 2026-09-22, **DOCA 3.5.0 is NVIDIA's latest published general
release**. The official repository's latest general-version directory is
`3.5.0`, its `latest/` content dates to the same 2026-09-01 publication, and
the DOCA release-note version selector starts with 3.5.0. There is no published
`3.5.1` repository or release-note entry. NVIDIA's 3.5 notes describe 3.6.0 as
an upcoming October 2026 release.

The repository also contains product-specific and older-branch builds, such as
3.4.2 OVS packages and 3.2 LTS updates. Those do not constitute a newer 3.5.x
general release.

### Relevant release-note fixes

No NVIDIA public release-note item exactly states “the first SR-IOV VF pair
works and a second VF pair on the same PF runs below 1 Mbps or times out.” The
following are the closest documented fixes found across DOCA 3.0 through 3.5:

| Release / component | NVIDIA reference | Documented item | Assessment for this failure |
|---|---|---|---|
| DOCA 3.5, BF3 firmware `32.50.1002` | `4923806 / 4867111 / 4927875` | RoCE communication between specific NIC pairs could enter a bad state after repeated QP create/destroy cycles and fail with transport retry-counter-exceeded errors. | **Strongest match.** A first perftest run followed by another VF/QP setup resembles the triggering lifecycle, and timeout is consistent. NVIDIA does not mention SR-IOV or multiple VFs, so it is not proof of the exact defect. |
| DOCA 3.5, BF3 firmware `32.50.1002` | `5174504` | Intensive parallel QP `INIT2RTR`/destroy operations could have high latency and reduce connection-establishment rate when PCC was enabled. | Related only if PCC is enabled; primarily connection-establishment latency rather than the reported persistent sub-1-Mbps data rate. |
| DOCA 3.5, BF3 firmware `32.50.1002` | `4947006 / 4980956 / 4982511` | Rare PCC steering races during QP creation/destruction could disrupt traffic or leak resources. | Plausible only for a PCC-enabled configuration; not explicitly VF-specific. |
| DOCA 3.4, BF3 firmware `32.49.1014` | `4860860` | QPs created during a PCC process transition could miss congestion-control state. | Related QP state issue, but requires a PCC transition and was already fixed before 3.5. |
| DOCA 3.2.3 BSP | `4892178` | A software reset in NIC mode while host VF traffic was active could crash the NIC subsystem. | Confirms a historical NIC-mode/host-VF defect, but the reproduction does not perform a reset during traffic. |
| DOCA 3.0, DOCA-Host/drivers | `4358857` | Increased CQ polling batch size to prevent `ib_write_bw` bandwidth degradation with a high number of QPs. | Similar benchmark symptom, but it concerns high QP scale and is a host-side fix, not the BF3 `32.50.1002` firmware fix. |

NVIDIA labels the closest RoCE/QP firmware defect as discovered in
`32.46.1006`; that does not establish whether it was introduced there or was
present in earlier `32.43.1014`. Consequently, the linkage to the observed
failure has **medium confidence**, not confirmed root-cause status.

The DOCA 3.5 known-issues lists were also checked. They contain other VF,
RoCE, and NIC-mode limitations, but none matches an eight-VF configuration
where a second ordinary RDMA VF pair stalls while the first pair works.

### Host-driver boundary

The full BFB updates the BlueField Arm image and device firmware; it does not
replace the x86 host's `mlx5_core`/`mlx5_ib` driver.

The current OpenShift installation is a new, clean cluster. No SR-IOV Network
Operator or SR-IOV network-node policy is configured, no VFs are being
created, and the nodes are using the RHCOS/RHEL in-tree mlx5 drivers. Thus the
historical failure cannot be reproduced in the cluster's present state.

On both nodes, `ethtool -i ens40f0np0` currently reports the driver version as
the RHEL kernel version, `5.14.0-687.35.1.el9_8.x86_64`, while the loaded
module exposes no separate version string, which is consistent with that
in-tree-driver deployment. Record the RHCOS release and kernel build as part of
the baseline.

For the firmware validation, install/configure the SR-IOV Network Operator and
set `numVfs: 8` only on the designated test PFs, while continuing to use the
same in-tree drivers. Do not introduce a DOCA-Host driver container or another
host-driver change in the same experiment. NVIDIA's vendor-stack guidance for
BlueField-3 uses DOCA-Host rather than MLNX_OFED, but that should be evaluated
as a separate controlled change only if the failure persists on firmware
`32.50.1002` with the in-tree driver.

### Required canary acceptance test

For the strongest before/after evidence, first reproduce the test on a
designated rail pair with the current `32.43.1014` firmware, the in-tree
drivers, and a narrowly scoped `numVfs: 8` policy. Then remove the test
workloads and VFs before the firmware operation. If this pre-update control is
skipped, a passing post-update test proves that the target configuration works,
but it cannot by itself prove that the firmware change fixed the historical
failure.

The firmware installation can first be proven on one device, but the RDMA
regression test requires a matched rail pair: one updated B3140H on each node.
After both endpoints report firmware `32.50.1002` and NIC mode:

1. Install/configure the SR-IOV Network Operator and a narrowly scoped policy
   with `numVfs: 8` for only the two canary PFs. Confirm that no vendor driver
   container is enabled and the nodes continue to use the in-tree mlx5
   modules.
2. Re-run the exact two-pod-pair sequence above with identical `ib_write_bw`
   options, message size, duration, GID, MTU, and rail mapping.
3. Require the second pair to establish reliably and achieve the expected rail
   bandwidth; “better than 1 Mbps” alone is not an acceptance threshold.
4. Repeat QP create/run/destroy cycles multiple times and test both directions,
   because the firmware fix refers to repeated cycles and specific NIC pairs.
5. Capture `dmesg`, perftest completion status/syndrome, and deltas for
   `req_cqe_error`, `resp_cqe_error`, `local_ack_timeout_err`,
   `rnr_nak_retry_err`, `implied_nak_seq_err`, `out_of_sequence`, and
   `out_of_buffer` from each VF's RDMA device.
6. Do not approve the remaining devices until the original failure is no longer
   reproducible across repeated cycles.

### Compatibility finding for the Dell B3140H SKU

The locally downloaded full bundle was inspected without flashing a device.
Its embedded BlueField-3 firmware catalog contains an exact entry for:

```text
900-9D3D4-00EN-HA0_Ax  MT_0000001069  32.50.1002
Nvidia BlueField-3 B3140H E-series HHHL SuperNIC ...
```

#### How the BFB was inspected

Two read-only inspections were performed, and they answer different
questions:

1. NVIDIA `doca-installer -b <bundle> --show-target-fw` reported the bundle's
   component versions, including BlueField-3 NIC firmware `32.50.1002`. This
   command alone does **not** establish support for a particular OPN or PSID.
2. The BFB was unpacked with the `mlx-mkbfb` utility supplied by NVIDIA's
   `rshim-user-space` project. Its initramfs contains an Arm root filesystem,
   an installer script, and the actual NIC firmware catalog/updater. The
   embedded Arm64 updater was executed with `--list` under user-mode Arm64
   emulation; no PCI device or rshim endpoint was passed to it.

**Execution environment:** the local macOS system was used to identify and
checksum the downloaded BFB. The BFB and inspection utilities were then copied
temporarily into `networking-debug-pod-dell-b200-01`, where
`doca-installer --show-target-fw` and the decisive embedded-catalog `--list`
query were run in the pod's Linux userspace. The temporary pod files were
removed afterward. The BFB record listing and extraction steps were also
independently repeated on macOS, but the Arm64 catalog binary was not executed
natively on macOS.

The essential extraction and query sequence was:

```bash
BFB=bf-bundle-3.5.0-89_26.07_ubuntu-24.04_64k_prod.bfb

# List and extract the BFB records. The large record of interest is initramfs.
python3 mlx-mkbfb -d "$BFB"
python3 mlx-mkbfb -x "$BFB"

# Extract the Arm root-filesystem archive and the install logic from initramfs.
gzip -dc dump-initramfs-v0 | \
    cpio -id ubuntu/image.tar.xz ubuntu/install.env/nic-fw
mkdir arm-root
tar -xJf ubuntu/image.tar.xz -C arm-root

# On an x86 host, run the embedded Arm64 catalog reader with qemu/proot.
# An Arm64 environment can run the binary directly from the extracted root.
UPDATER=/opt/mellanox/mlnx-fw-updater/firmware/mlxfwmanager_sriov_dis_aarch64_41692
proot -q qemu-aarch64-static -R arm-root \
    "$UPDATER" --list | \
    grep -E '900-9D3D4-00EN-HA0|MT_0000001069'
```

The matching catalog row reported OPN `900-9D3D4-00EN-HA0_Ax`, PSID
`MT_0000001069`, and firmware `32.50.1002`. This was a catalog listing only;
the updater was not given a device and no firmware operation was invoked.

The bundle's own `ubuntu/install.env/nic-fw` confirms how installation uses
this catalog. Its `provided_nic_fw()` function runs the same embedded updater
with `--list`, then performs an exact PSID lookup equivalent to:

```bash
mlxfwmanager_sriov_dis_aarch64_${cx_dev_id} --list | \
    grep -w "${PSID}"
```

Thus the full bundle does not choose NIC firmware from the filename. It reads
the device PSID and selects the matching catalog row. For these targets, that
row is the exact `MT_0000001069` entry above.

This is the exact NVIDIA OPN and PSID reported by all 20 intended targets.
It is stronger compatibility evidence than the generic bundle filename or the
result of `mlxfwmanager --online`.

`0KK4NR` was not inferred from the repository filename. It came from the
read-only PCI Vital Product Data on each target. For example, two queries of
the same physical PCI function on `dell-b200-01` produced:

| Identity source for `0000:18:00.0` | Reported identity |
|---|---|
| `lspci -s 0000:18:00.0 -vvv`, VPD `[PN]` | `0KK4NR` (EC `A04`) |
| VPD product name | BlueField-3 B3140H E-series HHHL SuperNIC |
| `mlxfwmanager -d 0000:18:00.0 --query` | OPN `900-9D3D4-00EN-HA0_Ax`; PSID `MT_0000001069` |

That same-BDF correlation is the evidence that `0KK4NR` is the OEM VPD part
number for the installed board whose NVIDIA identity is
`900-9D3D4-00EN-HA0_Ax` / `MT_0000001069`. The VPD field itself does not spell
out the word “Dell”; “Dell part” here means the OEM part number carried by the
adapter VPD in these Dell systems, as distinct from NVIDIA's `900-...` OPN.

The NVIDIA DOCA 3.5 repository publishes the firmware-only image under two
names:
`bf-fwbundle-3.5.0-89-0KK4NR_26.07_prod.bfb` and
`bf-fwbundle-3.5.0-89-900-9D3D4-00EN-HA0_26.07_prod.bfb`.

They are not two different firmware payloads. Direct inspection found that
the files are byte-for-byte identical and both have SHA-256
`99eb5a0bd9fdf2a263c375931ab92f35cf136d41c3819d9e2a032e116af87b08`.
Both contain the software identity
`fw-BlueField-3-rel-32_50_1002-900-9D3D4-00EN-HA0_Ax.bin`. The repository is
therefore providing an OEM-part-number alias and an NVIDIA-OPN alias for the
same BF-FW-Bundle. The filename omits the OPN's `_Ax` revision suffix, while
the embedded software identity retains it.

The PSID association is independently confirmed by the live same-BDF query
above and by the exact `MT_0000001069` entry in the full BF-Bundle's embedded
firmware catalog. This avoids relying on filename resemblance alone.

`mlxfwmanager --online` reporting no available update is therefore best read
as an online-catalog lookup result, not proof that the full bundle lacks a
compatible payload. Do not bypass compatibility checks with a forced burn or
change the PSID.

Technical payload compatibility is established. Dell support/qualification
for this exact XE9680L configuration remains a separate policy gate and should
be confirmed before production rollout.

### Inspected full-bundle contents

| Item | Observed value |
|---|---|
| Local file | `~/Downloads/bf-bundle-3.5.0-89_26.07_ubuntu-24.04_64k_prod.bfb` |
| SHA-256 | `823958b7fcf9f9354a640a88f0e3b06807204209fa9201c46b6e285202aee243` |
| DOCA | `3.5.0098` |
| BlueField BSP | `4.16.0.14075` |
| ATF | `4.16.0-8-gda930bca9` |
| UEFI | `4.16.0-48-g3e1cb60aa0` |
| BlueField-3 NIC firmware | `32.50.1002` |
| BMC firmware asset | `BF-26.07-8` |
| CEC firmware asset | `00.02.0208.0000_n02` |

The values above came from the NVIDIA `doca-installer --show-target-fw`
metadata reader and direct read-only inspection of the embedded firmware
catalog. The SHA-256 records the local artifact identity; it is not a
publisher signature or an independently published NVIDIA checksum.

### Full BF-Bundle versus BF-FW-Bundle

| Consideration | Full `bf-bundle` | `bf-fwbundle` |
|---|---|---|
| Scope | Arm OS/root filesystem, DOCA/runtime, BSP/boot firmware, NIC firmware, and included platform-firmware assets | Firmware-only payload; no Arm OS/DOCA runtime installation |
| Operational impact | Reimages the Arm boot installation and can replace local configuration | Smaller Day-2 firmware update; preserves the installed Arm OS |
| Consistency | NVIDIA validates the complete full-bundle combination | Selective update can leave firmware and installed Arm software on different release trains |
| SKU handling | Generic image embeds a multi-PSID catalog and selects the matching payload | DOCA repository offers explicit `0KK4NR` and NVIDIA-OPN variants |
| Guidance tension | Best fit for the stated consistency goal and prior B3220 experience | NVIDIA's NIC-mode-specific guidance recommends the firmware-only bundle for a normal NIC-mode upgrade |
| Decision here | **Preferred, with reimage safeguards and an exact-PSID canary** | Retained as the lower-impact fallback, not the selected approach |

The full bundle includes BMC firmware assets, but BMC upgrade behavior is
controlled by the installation configuration and may require BMC credentials.
Do not assume that merely installing the BFB updates every component.

## B3140H SuperNIC versus B3220 DPU

Both products use the BlueField-3 architecture and an integrated ConnectX-7,
but they package it for different roles. The difference is more than just Arm
core count.

| Concept | B3140H E-series SuperNIC | B3220 P-series DPU |
|---|---|---|
| Installed quantity | 10 per node; firmware targets | 2 per node; explicitly excluded |
| Default role/mode | SuperNIC, default NIC mode | DPU, default DPU mode |
| Arm resources | 8 cores, 16 GB DDR | 16 cores, 32 GB DDR |
| Network ports | 1 × QSFP112, up to 400GbE / NDR IB | 2 × QSFP112, up to 200GbE per port / NDR200 IB |
| Form factor | HHHL | FHHL |
| Typical role in this platform | Compute/east-west fabric adjacent to B200 GPUs | Infrastructure, management/storage, and network services |
| Arm datapath role in default mode | Arm cores are inactive in NIC mode; host owns the datapath | Arm cores and embedded CPU function manage/offload the datapath in DPU mode |

Product class does not make the mode immutable: BlueField can be configured
between NIC and DPU modes. Mode must therefore be verified per physical
device; it must not be inferred from the product name alone.

### Current operating-mode inventory

The mode was queried on every physical BlueField device with `mlxconfig`.
For BlueField-3, NVIDIA defines `INTERNAL_CPU_OFFLOAD_ENGINE=DISABLED(1)` as
NIC mode and `ENABLED(0)` as DPU mode.

| Node | Model / role | Physical BDFs | Current mode |
|---|---|---|---|
| `dell-b200-01` | 10 target B3140H SuperNICs | `18:00.0`, `1a:00.0`, `3a:00.0`, `4d:00.0`, `5d:00.0`, `9b:00.0`, `ba:00.0`, `ca:00.0`, `cc:00.0`, `db:00.0` | **All NIC mode** |
| `dell-b200-01` | B3220, non-frontend | `5f:00.0` | **DPU mode** |
| `dell-b200-01` | B3220, frontend `ens33f1np1` | `bc:00.0` | **NIC mode** |
| `dell-b200-02` | 10 target B3140H SuperNICs | `18:00.0`, `1a:00.0`, `3a:00.0`, `4d:00.0`, `5d:00.0`, `9b:00.0`, `ba:00.0`, `ca:00.0`, `cc:00.0`, `db:00.0` | **All NIC mode** |
| `dell-b200-02` | B3220, frontend `ens39f1np1` | `5f:00.0` | **NIC mode** |
| `dell-b200-02` | B3220, non-frontend | `bc:00.0` | **NIC mode** |

The internal ConnectX-7 mezzanine and Broadcom BCM5720 are not BlueField
devices, so BlueField NIC/DPU mode is not applicable to them. Their identity,
state, and roles remain documented in the non-target inventory below.

Some NIC-mode B3140H devices retain `ECPF(0)` values in the page-supplier or
eSwitch-manager fields. This does not change the mode determination: NVIDIA's
BlueField-3 procedure uses `INTERNAL_CPU_OFFLOAD_ENGINE` as the authoritative
NIC-versus-DPU indicator.

The earlier B3220 experience is conceptually consistent with this distinction:
when the Arm environment actively owns services or the datapath, component
alignment is especially visible. It is useful operational evidence, but not
by itself proof that every B3140H NIC-mode update requires a full reimage.

### Expected mode after the full BF-Bundle

The full bundle is **not expected to change these 10 devices from NIC mode to
DPU mode**. Read-only inspection of this exact BFB's `ubuntu/install.sh` found
that it queries `INTERNAL_CPU_OFFLOAD_ENGINE`, detects whether the device is
already in NIC mode, and adjusts the installation path accordingly. No command
in the extracted installation logic sets `INTERNAL_CPU_OFFLOAD_ENGINE` or
otherwise requests a NIC-to-DPU transition. B3140H SuperNIC SKUs are also
shipped in NIC mode by default.

Nevertheless, mode preservation should be treated as a verified outcome, not
an assumption. After the BFB installation and required reset/power cycle, each
target must report:

```text
INTERNAL_CPU_OFFLOAD_ENGINE  DISABLED(1)
```

If a target does not, explicitly request BlueField-3 NIC mode from the host:

```bash
mlxconfig -d <target-BDF> set INTERNAL_CPU_OFFLOAD_ENGINE=1
```

Then perform the required system-level reset; NVIDIA recommends a power cycle
for mode changes. This command is a recovery/enforcement step, not part of the
initial update while all targets already report NIC mode.

## Conclusion

Each server has:

- 8 NVIDIA B200 GPUs behind 8 Broadcom PEX890xx PCIe Gen5 switches.
- 10 BlueField-3 B3140H E-series SuperNICs, all sharing one of those switches
  with a B200 GPU.
- 2 BlueField-3 B3220 P-series DPUs, which **also** share a switch with a B200
  GPU but are a different SKU and PSID.
- 1 four-function ConnectX-7 adapter on its own root port, not behind a B200
  GPU switch.

The intended firmware-update set is therefore the 10 devices per server that
match **both** of these hardware identifiers:

| Required identity | Value |
|---|---|
| Part number | `900-9D3D4-00EN-HA0_Ax` |
| PSID | `MT_0000001069` |

PCIe location is useful for validating the platform design, but it must not be
the only update selector: the two `MT_0000000884` DPUs are also located behind
GPU switches.

## NIC model descriptions

### Firmware target: B3140H SuperNIC

**NVIDIA description:** Nvidia BlueField-3 B3140H E-series HHHL SuperNIC;
400GbE (default mode) / NDR IB; Single-port QSFP112; PCIe Gen5.0 x16; 8 Arm
cores; 16GB on board DDR; integrated BMC; Crypto Enabled.

| Property | Value |
|---|---|
| Quantity | 10 per node |
| NVIDIA part number | `900-9D3D4-00EN-HA0_Ax` |
| Dell VPD part number | `0KK4NR` |
| PSID | `MT_0000001069` |
| PCI identity | Mellanox/NVIDIA MT43244 BlueField-3 integrated ConnectX-7, `15b3:a2dc` |
| Host link | PCIe Gen5 x16; observed at 32 GT/s x16 |
| Network port | One QSFP112; 400GbE default mode or NDR InfiniBand |
| On-board compute | 8 Arm cores, 16 GB DDR, integrated BMC |
| Security feature | Crypto enabled |

### Non-target: B3220 DPU

**NVIDIA description:** NVIDIA BlueField-3 B3220 P-Series FHHL DPU; 200GbE
(default mode) / NDR200 IB; Dual-port QSFP112; PCIe Gen5.0 x16 with x16 PCIe
extension option; 16 Arm cores; 32GB on-board DDR; integrated BMC; Crypto
Enabled.

| Property | Value |
|---|---|
| Quantity | 2 per node |
| NVIDIA part number | `900-9D3B6-00CV-A_Ax` |
| Dell VPD part number | `0HFWRM` |
| VPD product name | `Bluefield-3 Dual Port 200 GbE QSFP Crypto DPU` |
| PSID | `MT_0000000884` |
| PCI identity | Mellanox/NVIDIA MT43244 BlueField-3 integrated ConnectX-7, `15b3:a2dc` |
| Host link | PCIe Gen5 x16; observed at 32 GT/s x16 |
| Network ports | Two QSFP112; 200GbE default mode or NDR200 InfiniBand |
| On-board compute | 16 Arm cores, 32 GB DDR, integrated BMC |
| Security feature | Crypto enabled |
| Role here | One DPU port per node carries the OVS `br-ex` frontend path |

### Non-target: internal ConnectX-7 mezzanine

| Property | Value |
|---|---|
| Quantity | 1 device / 4 PCI functions per node |
| VPD product name | `Nvidia ConnectX-7 mezz internal for Nvidia Umbriel system` |
| Part number | `692-9X760-00SE-S00` |
| Model code | `C7010Z` |
| PSID | `MT_0000001121` |
| PCI identity | Mellanox/NVIDIA MT2910 family ConnectX-7, `15b3:1021` |
| Host link | PCIe Gen4 x2; observed at 16 GT/s x2 |
| Host presentation | Four InfiniBand functions, each with one active IB port |
| Current firmware | `28.47.2526` |
| Current IB MTU | 512 bytes |
| Topology | NUMA 1, directly below root port `0000:80:01.0`; not on a B200 PEX890xx switch |

The four IPoIB netdevs were administratively down, while `ibv_devinfo`
reported all four underlying InfiniBand ports as `PORT_ACTIVE`. These states
describe different layers and are not contradictory.

### Non-target: Broadcom BCM5720

| Property | Value |
|---|---|
| Quantity | 1 dual-function adapter per node |
| Product | Broadcom NetXtreme BCM5720 Gigabit Ethernet PCIe |
| VPD part number | `BCM95720` |
| PCI identity | `14e4:165f`, Dell subsystem |
| Host link | PCIe Gen2; capable of 5 GT/s x2, observed at 5 GT/s x1 |
| Interfaces | `eno8303`, `eno8403` |
| Driver / firmware | `tg3`; `FFV23.22.4`, `bc 5720-v1.39` |
| State during collection | Both interfaces down with no IP address |

## Collection context

| Node | Debug pod | Namespace | Server serial | Board serial | BIOS | Kernel |
|---|---|---|---|---|---|---|
| `dell-b200-01` | `networking-debug-pod-dell-b200-01` | `default` | `BD5JDB4` | `.BD5JDB4.CNIVC004BF0170.` | Dell `2.10.1`, 2026-04-01 | `5.14.0-687.35.1.el9_8.x86_64` |
| `dell-b200-02` | `networking-debug-pod-dell-b200-02` | `default` | `9D5JDB4` | `.9D5JDB4.CNIVC004BL0373.` | Dell `2.10.1`, 2026-04-01 | `5.14.0-687.35.1.el9_8.x86_64` |

Both systems identify as Dell PowerEdge XE9680L with motherboard `0CCMT9`,
revision `A00`.

The earlier Ubuntu 24.04.4 identification was collected inside a debug
container. It describes that command's userspace and should not be treated as
the host operating-system identity without a host-root check.

Additional environment fields retained from the original `dell-b200-01`
inventory are architecture `x86_64` (64-bit) and the `inxi` compiler field
`gcc 2.35.2-72.el9`. The latter is recorded as reported; the unusual version
string should not be used to select host packages.

### Supplemental pre-update firmware components: `dell-b200-01`

`mlxfwmanager --online` reported the following component baselines in addition
to the primary NIC firmware versions:

| Physical devices | NIC firmware | UEFI | PXE | UEFI Virtio block | UEFI Virtio network | Online result |
|---|---|---|---|---|---|---|
| 10 B3140H targets and B3220 `0000:bc:00.0` | `32.43.1014` | `14.36.0016` | `3.7.0500` | `22.4.0014` | `21.4.0013` | `No matching online image` |
| B3220 `0000:5f:00.0` | `32.43.2402` | `14.36.0021` | `3.7.0500` | `22.4.0014` | `21.4.0013` | `No matching online image` |

The internal ConnectX-7 at `0000:81:00.0` was enumerated by
`mlxfwmanager` but that query failed with `ICMD bad parameter given`. Its
identity and firmware were subsequently resolved through `ethtool`, `devlink`,
and `ibv_devinfo`, as recorded in the non-target inventory.

## Frontend SSH network path

The external node IP is assigned to the Open vSwitch internal interface
`br-ex`, not directly to the physical NIC. The physical NIC is an unnumbered
Layer-2 port of `ovs-system`:

```text
SSH client -> physical DPU port -> Open vSwitch -> br-ex local port -> host sshd
```

| Node | SSH / node IP | Default route | `br-ex` MAC | Physical frontend port | PCI BDF | DPU |
|---|---|---|---|---|---|---|
| `dell-b200-01` | `10.14.202.18/24` on `br-ex` | `via 10.14.202.254 dev br-ex` | `5c:25:73:2a:0d:3d` | `ens33f1np1` | `0000:bc:00.1` | B3220 `MT_0000000884`, serial `IL0HFWRM7403146A00N3` |
| `dell-b200-02` | `10.14.202.19/24` on `br-ex` | `via 10.14.202.254 dev br-ex` | `5c:25:73:29:fd:5b` | `ens39f1np1` | `0000:5f:00.1` | B3220 `MT_0000000884`, serial `IL0HFWRM7403146A00K4` |

On both nodes, `ip -d link` identifies the physical interface as an
`openvswitch_slave` with master `ovs-system`. Each physical interface has the
same MAC as `br-ex`, is `UP,LOWER_UP`, and intentionally has no L3 address.
The host SSH listener was present on `0.0.0.0:22` and `[::]:22`.

`ovn-k8s-mp0` is the OVN-Kubernetes management port. Its `10.129.2.2/23`
address carries cluster overlay/service routing; it is not the frontend path
for the `10.14.202.x` SSH connection.

Because the debug pods use `hostNetwork: true`, commands in the pods inspect
the host network namespace: the host's interfaces, addresses, routes, and
listening sockets are visible. The node IP is not a separate pod-owned IP.

Firmware implication: the frontend ports are on the two non-target B3220 DPUs,
not on the 10 B3140H SuperNIC targets. The DPU PSID exclusion protects these
SSH paths from the SuperNIC bundle operation. Node drain and cold power-cycle
work will still interrupt access.

## PCIe switch groups

The BDF layout is identical on both servers. “Shared switch” below means the
devices have the same PEX890xx upstream switch in their sysfs PCI ancestry,
not merely that they have the same NUMA node.

| NUMA | PEX890xx switch | B200 GPU | Target B3140H SuperNICs | Non-target device on same switch |
|---:|---|---|---|---|
| 0 | `0000:16:00.0` | `0000:1b:00.0` | `0000:18:00.0`, `0000:1a:00.0` | — |
| 0 | `0000:38:00.0` | `0000:3c:00.0` | `0000:3a:00.0` | — |
| 0 | `0000:49:00.0` | `0000:4b:00.0` | `0000:4d:00.0` | — |
| 0 | `0000:5a:00.0` | `0000:5c:00.0` | `0000:5d:00.0` | B3220 DPU `0000:5f:00.0` |
| 1 | `0000:98:00.0` | `0000:9a:00.0` | `0000:9b:00.0` | — |
| 1 | `0000:b8:00.0` | `0000:bb:00.0` | `0000:ba:00.0` | B3220 DPU `0000:bc:00.0` |
| 1 | `0000:c8:00.0` | `0000:cd:00.0` | `0000:ca:00.0`, `0000:cc:00.0` | — |
| 1 | `0000:d8:00.0` | `0000:dc:00.0` | `0000:db:00.0` | — |

All listed B200 GPUs and BlueField-3 devices negotiate PCIe at 32.0 GT/s x16
in the supplied topology captures.

## Firmware targets: `dell-b200-01`

All 10 target interfaces were up when collected. All report firmware
`32.43.1014`, PSID `MT_0000001069`, and part number
`900-9D3D4-00EN-HA0_Ax`.

| NUMA | Switch | B200 | PCI BDF | Interface | RDMA | Base MAC | Firmware |
|---:|---|---|---|---|---|---|---|
| 0 | `16:00.0` | `1b:00.0` | `0000:18:00.0` | `ens40f0np0` | `mlx5_0` | `c4:70:bd:c6:e0:cc` | `32.43.1014` |
| 0 | `16:00.0` | `1b:00.0` | `0000:1a:00.0` | `ens42f0np0` | `mlx5_1` | `c4:70:bd:89:b6:ea` | `32.43.1014` |
| 0 | `38:00.0` | `3c:00.0` | `0000:3a:00.0` | `ens41f0np0` | `mlx5_2` | `c4:70:bd:c7:18:be` | `32.43.1014` |
| 0 | `49:00.0` | `4b:00.0` | `0000:4d:00.0` | `ens38f0np0` | `mlx5_3` | `c4:70:bd:89:b6:d4` | `32.43.1014` |
| 0 | `5a:00.0` | `5c:00.0` | `0000:5d:00.0` | `ens37f0np0` | `mlx5_4` | `c4:70:bd:c7:2b:a6` | `32.43.1014` |
| 1 | `98:00.0` | `9a:00.0` | `0000:9b:00.0` | `ens32f0np0` | `mlx5_9` | `c4:70:bd:c7:17:a0` | `32.43.1014` |
| 1 | `b8:00.0` | `bb:00.0` | `0000:ba:00.0` | `ens31f0np0` | `mlx5_10` | `c4:70:bd:c6:dc:96` | `32.43.1014` |
| 1 | `c8:00.0` | `cd:00.0` | `0000:ca:00.0` | `ens36f0np0` | `mlx5_13` | `c4:70:bd:c7:18:3a` | `32.43.1014` |
| 1 | `c8:00.0` | `cd:00.0` | `0000:cc:00.0` | `ens34f0np0` | `mlx5_14` | `c4:70:bd:bd:f5:d8` | `32.43.1014` |
| 1 | `d8:00.0` | `dc:00.0` | `0000:db:00.0` | `ens35f0np0` | `mlx5_15` | `c4:70:bd:bd:f6:5c` | `32.43.1014` |

## Firmware targets: `dell-b200-02`

All 10 target interfaces were up when collected. All report firmware
`32.43.1014`, PSID `MT_0000001069`, and part number
`900-9D3D4-00EN-HA0_Ax`.

| NUMA | Switch | B200 | PCI BDF | Interface | RDMA | Base MAC | Firmware |
|---:|---|---|---|---|---|---|---|
| 0 | `16:00.0` | `1b:00.0` | `0000:18:00.0` | `ens40f0np0` | `mlx5_0` | `c4:70:bd:cb:ff:60` | `32.43.1014` |
| 0 | `16:00.0` | `1b:00.0` | `0000:1a:00.0` | `ens42f0np0` | `mlx5_1` | `c4:70:bd:78:d0:32` | `32.43.1014` |
| 0 | `38:00.0` | `3c:00.0` | `0000:3a:00.0` | `ens41f0np0` | `mlx5_2` | `c4:70:bd:c7:17:74` | `32.43.1014` |
| 0 | `49:00.0` | `4b:00.0` | `0000:4d:00.0` | `ens38f0np0` | `mlx5_3` | `c4:70:bd:c7:1d:78` | `32.43.1014` |
| 0 | `5a:00.0` | `5c:00.0` | `0000:5d:00.0` | `ens37f0np0` | `mlx5_4` | `c4:70:bd:78:d0:1c` | `32.43.1014` |
| 1 | `98:00.0` | `9a:00.0` | `0000:9b:00.0` | `ens32f0np0` | `mlx5_11` | `c4:70:bd:c7:1d:8e` | `32.43.1014` |
| 1 | `b8:00.0` | `bb:00.0` | `0000:ba:00.0` | `ens31f0np0` | `mlx5_12` | `c4:70:bd:c6:df:82` | `32.43.1014` |
| 1 | `c8:00.0` | `cd:00.0` | `0000:ca:00.0` | `ens36f0np0` | `mlx5_15` | `c4:70:bd:c6:e9:90` | `32.43.1014` |
| 1 | `c8:00.0` | `cd:00.0` | `0000:cc:00.0` | `ens34f0np0` | `mlx5_16` | `c4:70:bd:cc:02:0a` | `32.43.1014` |
| 1 | `d8:00.0` | `dc:00.0` | `0000:db:00.0` | `ens35f0np0` | `mlx5_17` | `c4:70:bd:c6:e9:bc` | `32.43.1014` |

## Detailed non-target NIC inventory

### BlueField-3 B3220 DPUs

| Node | BDF | Board serial | Base MAC | Firmware | Interfaces / state | Role and driver state |
|---|---|---|---|---|---|---|
| `dell-b200-01` | `0000:5f:00.0`, `.1` | `VN0HFWRMFCBNV59T601Q` | `54:9b:24:e2:fd:3a` | `32.43.2402` | No netdev or RDMA device | Not bound to `mlx5_core`; not the frontend |
| `dell-b200-01` | `0000:bc:00.0`, `.1` | `IL0HFWRM7403146A00N3` | `5c:25:73:2a:0d:3c` | `32.43.1014` | `ens33f0np0` / `mlx5_11` down; `ens33f1np1` / `mlx5_12` up | Port 1 is the `br-ex` frontend uplink |
| `dell-b200-02` | `0000:5f:00.0`, `.1` | `IL0HFWRM7403146A00K4` | `5c:25:73:29:fd:5a` | `32.43.1014` | `ens39f0np0` / `mlx5_5` down; `ens39f1np1` / `mlx5_6` up | Port 1 is the `br-ex` frontend uplink |
| `dell-b200-02` | `0000:bc:00.0`, `.1` | `IL0HFWRM7403146A00MT` | `5c:25:73:2a:0b:c0` | `32.43.1014` | `ens33f0np0` / `mlx5_13` down; `ens33f1np1` / `mlx5_14` up | Bound to `mlx5_core`; not the frontend |

All four physical DPUs use Dell part `0HFWRM`, NVIDIA part
`900-9D3B6-00CV-A_Ax`, and PSID `MT_0000000884`. They are excluded from the
B3140H firmware operation even though `0000:5f:00.0` and `0000:bc:00.0` share
PEX890xx switches with B200 GPUs.

### Internal ConnectX-7 mezzanines

| Node | BDFs | Board serial | Base node GUID | Firmware | Netdevs / RDMA devices | Observed state |
|---|---|---|---|---|---|---|
| `dell-b200-01` | `0000:81:00.0` through `.3` | `MT25066014U9` | `7c8c:0903:001b:555a` | `28.47.2526` | `ibo6-ibo9` / `mlx5_5-mlx5_8` | IPoIB netdevs down; four IB ports active |
| `dell-b200-02` | `0000:81:00.0` through `.3` | `MT2517603AXG` | `3825:f303:0047:06f0` | `28.47.2526` | `ibo6-ibo9` / `mlx5_7-mlx5_10` | IPoIB netdevs down; four IB ports active |

Both use part `692-9X760-00SE-S00` and PSID `MT_0000001121` and are excluded.
`mlxfwmanager` and `mstflint` could not query them normally; their firmware
and PSID were obtained from `ethtool -i`, `ibv_devinfo`, and `devlink`.

### Broadcom BCM5720 adapters

| Node | BDF | Interface | MAC | Link state | Firmware |
|---|---|---|---|---|---|
| `dell-b200-01` | `0000:02:00.0` | `eno8303` | `c4:cb:e1:f9:a0:a4` | Down | `FFV23.22.4`, `bc 5720-v1.39` |
| `dell-b200-01` | `0000:02:00.1` | `eno8403` | `c4:cb:e1:f9:a0:a5` | Down | `FFV23.22.4`, `bc 5720-v1.39` |
| `dell-b200-02` | `0000:02:00.0` | `eno8303` | `c4:cb:e1:f9:b3:4c` | Down | `FFV23.22.4`, `bc 5720-v1.39` |
| `dell-b200-02` | `0000:02:00.1` | `eno8403` | `c4:cb:e1:f9:b3:4d` | Down | `FFV23.22.4`, `bc 5720-v1.39` |

These ports use VPD part `BCM95720`, have no IP address, and are not involved
in the observed frontend SSH path.

## Original `lshw` path correlation: `dell-b200-01`

This preserves the hardware paths from the initial collection while replacing
the original pending PCI fields with the later sysfs-verified BDF mappings.
`lshw` paths are observation-time topology labels; PCI BDF, OPN, and PSID are
the update-selection identities.

| `lshw` path | PCI BDF | RDMA device | Interface | Observed state / resolution |
|---|---|---|---|---|
| `/0/104/0/0/0` | `0000:18:00.0` | `mlx5_0` | `ens40f0np0` | Up; target B3140H |
| `/0/104/0/2/0` | `0000:1a:00.0` | `mlx5_1` | `ens42f0np0` | Up; target B3140H |
| `/0/105/0/0/0` | `0000:3a:00.0` | `mlx5_2` | `ens41f0np0` | Up; target B3140H |
| `/0/106/0/2/0` | `0000:4d:00.0` | `mlx5_3` | `ens38f0np0` | Up; target B3140H |
| `/0/107/0/1/0` | `0000:5d:00.0` | `mlx5_4` | `ens37f0np0` | Up; target B3140H |
| `/0/107/0/3/0` | `0000:5f:00.0` | — | — | B3220 in DPU mode; no host netdev/RDMA device |
| `/0/107/0/3/0.1` | `0000:5f:00.1` | — | — | Second function of the same B3220 |
| `/0/109/0` | `0000:81:00.0` | `mlx5_5` | `ibo6` | IPoIB netdev down; IB port active |
| `/0/109/0.1` | `0000:81:00.1` | `mlx5_6` | `ibo7` | IPoIB netdev down; IB port active |
| `/0/109/0.2` | `0000:81:00.2` | `mlx5_7` | `ibo8` | IPoIB netdev down; IB port active |
| `/0/109/0.3` | `0000:81:00.3` | `mlx5_8` | `ibo9` | IPoIB netdev down; IB port active |
| `/0/10a/0/1/0` | `0000:9b:00.0` | `mlx5_9` | `ens32f0np0` | Up; target B3140H |
| `/0/10b/0/0/0` | `0000:ba:00.0` | `mlx5_10` | `ens31f0np0` | Up; target B3140H |
| `/0/10b/0/2/0` | `0000:bc:00.0` | `mlx5_11` | `ens33f0np0` | Down; B3220 port 0 |
| `/0/10b/0/2/0.1` | `0000:bc:00.1` | `mlx5_12` | `ens33f1np1` | Up; B3220 frontend port 1 |
| `/0/10c/0/0/0` | `0000:ca:00.0` | `mlx5_13` | `ens36f0np0` | Up; target B3140H |
| `/0/10c/0/2/0` | `0000:cc:00.0` | `mlx5_14` | `ens34f0np0` | Up; target B3140H |
| `/0/10d/0/1/0` | `0000:db:00.0` | `mlx5_15` | `ens35f0np0` | Up; target B3140H |
| `/0/101/0` | `0000:02:00.0` | — | `eno8303` | Broadcom BCM5720; down |
| `/0/101/0.1` | `0000:02:00.1` | — | `eno8403` | Broadcom BCM5720; down |

### Reusable interface-to-PCI collection command

The original inventory requested this mapping. The results are now populated
above and in the per-node target tables, but the collection command is retained
for the final pre-update snapshot:

```bash
printf '| Interface | PCI BDF | RDMA device | Driver | Firmware | State |\n'
printf '|---|---|---|---|---|---|\n'
for net_path in /sys/class/net/*; do
    iface=${net_path##*/}
    pci_path=$(readlink -f "$net_path/device" 2>/dev/null) || continue
    pci_bdf=${pci_path##*/}
    [[ $pci_bdf =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || continue

    rdma='—'
    for rdma_path in /sys/class/infiniband/*; do
        [[ -e "$rdma_path/device/net/$iface" ]] || continue
        rdma=${rdma_path##*/}
        break
    done

    driver=$(ethtool -i "$iface" 2>/dev/null |
        awk -F ': ' '$1 == "driver" { print $2 }')
    firmware=$(ethtool -i "$iface" 2>/dev/null |
        awk -F ': ' '$1 == "firmware-version" { print $2 }')
    state=$(<"$net_path/operstate")

    printf '| `%s` | `%s` | `%s` | `%s` | `%s` | %s |\n' \
        "$iface" "$pci_bdf" "$rdma" "${driver:-—}" \
        "${firmware:-—}" "$state"
done | sort -t '|' -k 3,3

# Also retain PCI functions that currently expose no netdev.
lspci -Dnnk | grep -A3 -Ei 'Mellanox|NVIDIA.*(BlueField|ConnectX)'
```

### Resolution of the original open inventory questions

| Original question | Resolution |
|---|---|
| Populate interface-to-PCI mappings | Completed for both nodes using sysfs; captured in the target, non-target, frontend, and correlation tables. |
| Explain `/0/107/0/3/0{,.1}` with no netdev | They are functions `0000:5f:00.0/.1` of the B3220 on `dell-b200-01`; it is currently in DPU mode and has no host netdev/RDMA mapping. |
| Investigate ConnectX-7 `0000:81:00.0` | Identified as four-function internal mezzanine `692-9X760-00SE-S00`, PSID `MT_0000001121`, firmware `28.47.2526`; excluded from this update. |
| Confirm target firmware and PSID match | Completed: exact OPN `900-9D3D4-00EN-HA0_Ax` and PSID `MT_0000001069` are present in the inspected full BFB catalog. |

## Read-only target guardrail

Run this in either debug pod before any update work. It selects by PSID from
the driver's firmware identity and refuses to accept anything other than 10
targets.

```bash
TARGET_PSID=MT_0000001069
mapfile -t targets < <(
    for net_path in /sys/class/net/*; do
        iface=${net_path##*/}
        pci_path=$(readlink -f "$net_path/device" 2>/dev/null) || continue
        bdf=${pci_path##*/}
        fw=$(ethtool -i "$iface" 2>/dev/null |
            awk -F ': ' '$1 == "firmware-version" { print $2 }')
        [[ $fw == *"($TARGET_PSID)"* ]] || continue
        printf '%s|%s|%s\n' "$bdf" "$iface" "$fw"
    done | sort
)

printf '%s\n' "${targets[@]}"
if (( ${#targets[@]} != 10 )); then
    printf 'ERROR: expected 10 targets, found %d\n' "${#targets[@]}" >&2
    exit 1
fi
```

This is an inventory check, not an update command. A firmware workflow must
also query the PSID immediately before flashing each physical device.

## Execution gates and rollout sequence

The package type and technical identity match are decided; the installation is
not yet authorized. Complete these gates before constructing an update command:

1. Confirm Dell support/qualification for DOCA 3.5.0/BSP 4.16 on XE9680L and
   archive the downloaded file with the SHA-256 recorded above.
2. Establish the `rshimN` to physical PCI BDF mapping on each node. No
   `/dev/rshim*/misc` devices were present in either debug pod during the
   original collection. Never assume that rshim numbering is stable.
3. For every candidate, independently verify the live PSID is
   `MT_0000001069`, the OPN is `900-9D3D4-00EN-HA0_Ax`, and the mapped BDF is
   one of the 10 targets for that node in this document. Abort on a per-node
   count other than 10.
4. Use a current NVIDIA installer to run `--show-target-fw`,
   `--show-running-fw`, and `--compare` against each mapped target. Save the
   output as the formal preflight record.
5. Confirm that the target has no unexpected Arm-side workload or persistent
   state. Preservation of the current Arm OS is not required for the intended
   NIC-mode/CX-7-like use. Decide explicitly whether BMC/CEC components are in
   scope and prepare the required installer configuration/credentials if BMC
   update is intended.
6. Define node drain, workload evacuation, maintenance access,
   reset/cold-power-cycle, and recovery procedures. There are currently no VFs
   to tear down; add VF teardown to the procedure once the SR-IOV validation
   policy is introduced. The frontend DPU is excluded from the target set, but
   node reset/power work will still break SSH access.
7. Installation-canary a single B3140H on one drained node. Reconfirm PSID
   immediately before installation; install the full bundle only through that
   device's mapped rshim; then complete the documented reset/power sequence.
8. Validate Arm boot health, NIC firmware `32.50.1002`, link state, PCIe
   width/speed, RDMA/netdev mapping, BMC/CEC state, and GPU/NIC topology. As a
   hard acceptance criterion, `mlxconfig` must report
   `INTERNAL_CPU_OFFLOAD_ENGINE=DISABLED(1)` (NIC mode).
9. Update and validate the corresponding rail endpoint on the other node.
   Configure the two canary PFs for eight VFs and run the required two-node
   SR-IOV/RDMA acceptance test. This matched pair is necessary to test the
   reported defect without mixing old and new endpoint firmware.
10. Proceed to the remaining 18 devices only after the canary rail pair is
    accepted. Complete and validate each subsequent device before continuing.

Hard exclusions for every step are PSID `MT_0000000884` (the B3220 DPUs,
including the frontend path) and `MT_0000001121` (the internal ConnectX-7).

## Evidence sources

- `dell-b200-01_numa_0.pdf` and `dell-b200-01_numa_1.pdf`
- `dell-b200-02_numa_0.pdf` and `dell-b200-02_numa_1.pdf`
- [`harvard-cns/intrahost-topo`](https://github.com/harvard-cns/intrahost-topo)
- Live sysfs PCI ancestry and `lspci` from both debug pods
- Initial `lshw` and `ibdev2netdev` interface/RDMA observations
- PCI VPD and negotiated-link data from `lspci -vvv`
- `ethtool -i` for interface firmware/PSID data
- `devlink dev info` and `ibv_devinfo` for ConnectX-7 identity and IB state
- `mlxfwmanager --query` for BlueField part number, PSID, MAC, and firmware
- Read-only `mlxconfig` mode queries on every B3140H and B3220 physical device
- Read-only inspection of the downloaded BFB with NVIDIA `doca-installer`,
  `bfb-tool`, and the bundle's embedded firmware catalog
- [NVIDIA BF-Bundle Installation and Upgrade](https://docs.nvidia.com/doca/sdk/bf-bundle-installation-and-upgrade/)
- [NVIDIA DOCA Installation Guide for Linux](https://docs.nvidia.com/doca/sdk/doca-installation-guide-for-linux/)
- [NVIDIA public DOCA repository index](https://linux.mellanox.com/public/repo/doca/)
- [DOCA 3.5.0 changes and new features](https://networking-docs.nvidia.com/doca/archive/3-5-0/changes-and-new-features)
- [DOCA 3.5.0 bug fixes, including BlueField-3 firmware](https://networking-docs.nvidia.com/doca/archive/3-5-0/bug-fixes-in-this-version#BlueField-3-Firmware-Bug-Fixes)
- [DOCA 3.5.0 known issues](https://networking-docs.nvidia.com/doca/archive/3-5-0/known-issues)
- [DOCA 3.5.0 supported platforms and firmware versions](https://networking-docs.nvidia.com/doca/archive/3-5-0/general-support)
- [DOCA 3.4.0 bug fixes](https://networking-docs.nvidia.com/doca/archive/3-4-0/bug-fixes-in-this-version)
- [DOCA 3.2.3 bug fixes](https://networking-docs.nvidia.com/doca/archive/3-2-3/bug-fixes-in-this-version)
- [DOCA 3.0.0 bug fixes](https://networking-docs.nvidia.com/doca/archive/3-0-0/bug-fixes-in-this-version)
- [NVIDIA BlueField Modes of Operation](https://docs.nvidia.com/doca/sdk/bluefield-modes-of-operation.pdf)
- [NVIDIA BlueField-3 product documentation](https://networking-docs.nvidia.com/bf3dpu)
- [NVIDIA DOCA 3.5.0 BF-FW-Bundle repository](https://linux.mellanox.com/public/repo/doca/3.5.0/bf-fwbundle/)
- [Mellanox/NVIDIA `rshim-user-space` source (`mlx-mkbfb`)](https://github.com/Mellanox/rshim-user-space)
