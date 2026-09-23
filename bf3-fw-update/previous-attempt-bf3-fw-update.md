# BF3 SuperNIC Firmware Upgrade via bf-fwbundle BFB + rshim

Firmware upgrade procedure for Dell OEM BF3 SuperNICs (PSID `MT_0000001069`) on bare-metal OpenShift nodes. These NICs have no `.bin` on NVIDIA's public firmware site — the only flash path is pushing a bf-fwbundle BFB file through rshim.

## Hardware Context

- **Target NICs**: BF3 SuperNICs — 10 per node, single-port 400GbE (PSID `MT_0000001069`)
- **Not targeted**: BF3 DPUs — 2 per node, dual-port 200GbE (PSID `MT_0000000884`) — different SKU, different BFB
- **BFB file**: `bf-fwbundle-3.4.0-92-0KK4NR_26.04_prod.bfb` (Dell 0KK4NR SKU)
- **BFB URL**: `https://linux.mellanox.com/public/repo/doca/3.4.0/bf-fwbundle/bf-fwbundle-3.4.0-92-0KK4NR_26.04_prod.bfb`
- **Firmware versions**: 32.43.1014 (old) → 32.49.1014 (new, qualified for DOCA 3.4.0)

## Order of Operations

### 1. Disable SR-IOV

Disable SR-IOV before flashing to avoid interference from VF config during firmware work.

```bash
# Backup existing config
oc get sriovnetworknodepolicies -n openshift-sriov-network-operator -o yaml > mellanox-firmware-update/sriov-policies-backup.yaml
oc get sriovnetwork -n openshift-sriov-network-operator -o yaml > mellanox-firmware-update/sriov-networks-backup.yaml

# Delete all policies and networks
oc delete sriovnetworknodepolicy -n openshift-sriov-network-operator --all
oc delete sriovnetwork -n openshift-sriov-network-operator --all

# Wait for config daemons to sync — VFs should go to 0 on all PFs
oc get sriovnetworknodestates -n openshift-sriov-network-operator \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.status.syncStatus}{"\n"}{end}'
```

### 2. Deploy mfttool Pod

Apply the namespace/SA and pod spec for each node:

```bash
oc apply -f mellanox-firmware-update/mfttool-project.yaml
oc apply -f mellanox-firmware-update/mfttool-pod-dell-b200-1.yaml
oc apply -f mellanox-firmware-update/mfttool-pod-dell-b200-2.yaml
```

The pod must have: `hostNetwork: true`, `privileged: true`, and host `/dev` mounted at `/dev` (required for rshim CUSE devices).

### 3. Pod Setup (once per fresh pod)

```bash
POD=mfttool-pod-dell-b200-1  # or -2

# Install fuse-libs (required by rshim)
oc exec -n mfttool $POD -- dnf install -y fuse-libs

# Copy rshim binaries (RPM URL is 404, use cached copies)
# Source: extract from any pod that has DOCA/rshim installed, or from a BFB
for f in rshim bfb-install bfb-tool mlx-mkbfb; do
  oc cp /tmp/rshim-transfer/$f mfttool/$POD:/usr/sbin/$f
done
oc exec -n mfttool $POD -- chmod +x /usr/sbin/rshim /usr/sbin/bfb-install \
  /usr/sbin/bfb-tool /usr/sbin/mlx-mkbfb

# Load CUSE kernel module
oc exec -n mfttool $POD -- modprobe cuse

# Start rshim — MUST use -F (force) to take over backends
oc exec -n mfttool $POD -- bash -c 'nohup rshim -b pcie -f -F -l 3 > /dev/null 2>&1 &'
# Wait 5-8 seconds for all devices to appear

# Download BFB firmware bundle (~193 MB)
oc exec -n mfttool $POD -- wget -q -O /tmp/fw.bfb \
  "https://linux.mellanox.com/public/repo/doca/3.4.0/bf-fwbundle/bf-fwbundle-3.4.0-92-0KK4NR_26.04_prod.bfb"
```

### 4. Verify Devices

List all rshim devices with current firmware and PSID:

```bash
oc exec -n mfttool $POD -- bash -c '
  for dev in /dev/rshim*/misc; do
    [ -e "$dev" ] || continue
    devname=$(dirname "$dev" | xargs basename)
    pci=$(cat "$dev" | grep DEV_NAME | awk "{print \$2}" | sed "s/pcie-//;s/\.[0-9]*$/.0/")
    fw=$(flint -d "$pci" q 2>/dev/null | grep "^FW Version:" | head -1 | awk "{print \$3}")
    psid=$(flint -d "$pci" q 2>/dev/null | grep "^PSID:" | awk "{print \$2}")
    echo "$devname -> $pci fw=$fw psid=$psid"
  done'
```

Only flash devices with PSID `MT_0000001069`. Devices with `MT_0000000884` are DPUs — do not flash with this BFB.

### 5. Flash NICs

Flash one NIC at a time, one node at a time. Each flash takes ~10 minutes.

```bash
oc exec -n mfttool $POD -- bfb-install --bfb /tmp/fw.bfb --rshim rshim0
```

Or use the script to flash all eligible NICs:

```bash
./flash-bf3-firmware.sh mfttool-pod-dell-b200-1 all
```

After each flash, verify with `flint`:

```bash
oc exec -n mfttool $POD -- flint -d 0000:18:00.0 q | grep "FW Version"
```

### 6. Cold Reboot via iDRAC

Firmware is staged but **not active** until a cold reboot. Use iDRAC power cycle — **not** a warm reboot (`reboot` / `systemctl reboot`), which may not fully reset NIC PCIe state.

Do one node at a time so the cluster API stays available (on single-master clusters, do the worker first).

### 7. Verify Firmware

After reboot, confirm all SuperNIC PFs report the new firmware:

```bash
oc debug node/<hostname> -- chroot /host bash -c '
  set -x
  for iface in ens40f0np0 ens42f0np0 ens41f0np0 ens38f0np0 ens37f0np0 \
    ens32f0np0 ens31f0np0 ens36f0np0 ens34f0np0 ens35f0np0; do
    ethtool -i $iface 2>/dev/null | grep firmware-version
  done'
```

### 8. Re-enable SR-IOV

Re-run the SR-IOV generator job or re-apply the backed-up policies/networks:

```bash
# Delete any old completed job first
oc delete job nic-resource-generator -n llm-d-setup --ignore-not-found

# Re-run the generator
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/14-sriov-vf-config/

# Wait for sync
oc get sriovnetworknodestates -n openshift-sriov-network-operator \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.status.syncStatus}{"\n"}{end}'
```

The SR-IOV config daemon will run `mstconfig` on each PF to set `SRIOV_EN=True` and `NUM_OF_VFS=8`, then reboot each node. On a single-master cluster, see the gotcha below.

## Gotchas

### Dell OEM PSID has no .bin

`mlxfwmanager --online` will say "No matching image found" for PSID `MT_0000001069`. The bf-fwbundle BFB via rshim is the only path.

### rshim -F (force) is required

Without `-F`, some BF3s show "another backend already attached" and are invisible. Always use `rshim -b pcie -f -F -l 3`.

### bfb-install hangs after successful flash

The `bfb-install` subprocess `cat /dev/rshimN/console` waits for EOF that never comes. If it runs longer than ~12 minutes, check `flint -d <pci> q` directly. If firmware shows updated, kill the `bfb-install` process and move on.

### Zombie processes from rshim restarts

If you kill and restart rshim mid-session, zombie processes accumulate and hold CUSE resources. If rshim misbehaves after a restart, delete the entire pod and recreate it for a clean process space. Never restart rshim — just start fresh.

### rshim CUSE devices are character special files

Use `[ -e "$dev" ]`, not `[ -f "$dev" ]`, when iterating over `/dev/rshim*/misc`.

## Appendix: mfttool Pod YAML

Namespace and ServiceAccount:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mfttool
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mfttool
  namespace: mfttool
```

Pod (set `kubernetes.io/hostname` to the target node):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mfttool-pod
  namespace: mfttool
spec:
  nodeSelector:
    kubernetes.io/hostname: <node-fqdn>
  hostNetwork: true
  serviceAccountName: mfttool
  containers:
  - name: mfttool
    image: quay.io/dagray/rdma-tools:mfttools-1.0.0
    imagePullPolicy: Always
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-lib-modules
      mountPath: /lib/modules
    - name: host-usr
      mountPath: /host/usr
    - name: host-dev
      mountPath: /dev
  volumes:
  - name: host-lib-modules
    hostPath:
      path: /lib/modules
  - name: host-usr
    hostPath:
      path: /usr
  - name: host-dev
    hostPath:
      path: /dev
```

The critical volume mount is `/dev` — without it, rshim cannot create CUSE devices. The `host-lib-modules` mount is needed for `modprobe cuse`.

## Appendix: flash-bf3-firmware.sh

Lists devices when run without a rshim target, flashes one or all eligible NICs (filters by PSID to skip DPUs).

```bash
#!/bin/bash
set -euo pipefail

NAMESPACE="mfttool"
BFB_PATH="/tmp/fw.bfb"
TARGET_FW="32.49.1014"
TARGET_PSID="MT_0000001069"

POD_NAME="${1:?Usage: $0 <pod-name> [rshim-device|all]}"
RSHIM_TARGET="${2:-}"

run_in_pod() {
    oc exec -n "$NAMESPACE" "$POD_NAME" -- bash -c "$1"
}

echo "=== Pre-flash firmware check ==="
run_in_pod '
    for dev in /dev/rshim*/misc; do
        [ -e "$dev" ] || continue
        devname=$(dirname "$dev" | xargs basename)
        pci_fn=$(cat "$dev" 2>/dev/null | grep DEV_NAME | awk "{print \$2}" | sed "s/pcie-//")
        pci_base=$(echo "$pci_fn" | sed "s/\.[0-9]*$/.0/")
        fw=$(flint -d "$pci_base" q 2>/dev/null | grep "^FW Version:" | head -1 | awk "{print \$3}")
        psid=$(flint -d "$pci_base" q 2>/dev/null | grep "^PSID:" | awk "{print \$2}")
        echo "  $devname ($pci_base): fw=$fw psid=$psid"
    done
'

if [ -z "$RSHIM_TARGET" ]; then
    echo ""
    echo "No rshim device specified. Run with a second argument:"
    echo "  $0 $POD_NAME rshim0     # flash one NIC"
    echo "  $0 $POD_NAME all        # flash all that need it (correct PSID only)"
    exit 0
fi

if [ "$RSHIM_TARGET" = "all" ]; then
    run_in_pod '
        for dev in /dev/rshim*/misc; do
            [ -e "$dev" ] || continue
            devname=$(dirname "$dev" | xargs basename)
            pci_fn=$(cat "$dev" 2>/dev/null | grep DEV_NAME | awk "{print \$2}" | sed "s/pcie-//")
            pci_base=$(echo "$pci_fn" | sed "s/\.[0-9]*$/.0/")
            fw=$(flint -d "$pci_base" q 2>/dev/null | grep "^FW Version:" | head -1 | awk "{print \$3}")
            psid=$(flint -d "$pci_base" q 2>/dev/null | grep "^PSID:" | awk "{print \$2}")
            if [ "$psid" != "'"$TARGET_PSID"'" ]; then
                echo "SKIP $devname ($pci_base): wrong PSID $psid"
                continue
            fi
            if [ "$fw" = "'"$TARGET_FW"'" ]; then
                echo "SKIP $devname ($pci_base): already $fw"
                continue
            fi
            echo ""
            echo ">>> FLASH $devname ($pci_base) from $fw -> '"$TARGET_FW"'"
            bfb-install --bfb '"$BFB_PATH"' --rshim "$devname" 2>&1 | tail -5
            echo "<<< $devname done"
        done
    '
else
    echo "Flashing $RSHIM_TARGET..."
    run_in_pod "bfb-install --bfb $BFB_PATH --rshim $RSHIM_TARGET 2>&1 | tail -10"
fi

echo ""
echo "=== IMPORTANT ==="
echo "Firmware is staged but NOT active. A cold reboot / power cycle is required."
echo "After reboot, verify with: ethtool -i <interface> | grep firmware"
```

