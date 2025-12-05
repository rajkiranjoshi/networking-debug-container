#!/bin/bash

echo "======================================================================="
echo "IOMMU and PCI ACS Configuration Check"
echo "======================================================================="
echo ""

# ============================================================================
# Part 1: Check if IOMMU is enabled via kernel command line
# ============================================================================
echo "1. IOMMU Status"
echo "-----------------------------------------------------------------------"

cmdline=$(cat /proc/cmdline 2>/dev/null)

if [ -z "$cmdline" ]; then
    echo "❌ Unable to read /proc/cmdline"
    exit 1
fi

# Detect CPU vendor to determine which IOMMU to check
cpu_vendor=$(lscpu | grep "Vendor ID" | awk '{print $3}')

iommu_status=""
if [[ "$cpu_vendor" == "GenuineIntel" ]] || echo "$cmdline" | grep -q "intel_iommu"; then
    # Intel system
    if echo "$cmdline" | grep -q "intel_iommu=on"; then
        iommu_status="❌ Intel IOMMU: ENABLED (intel_iommu=on found in kernel cmdline)"
    else
        iommu_status="✅ Intel IOMMU: DISABLED (intel_iommu=on NOT found in kernel cmdline)"
    fi
elif [[ "$cpu_vendor" == "AuthenticAMD" ]] || echo "$cmdline" | grep -q "amd_iommu"; then
    # AMD system
    if echo "$cmdline" | grep -q "amd_iommu=on"; then
        iommu_status="❌ AMD IOMMU: ENABLED (amd_iommu=on found in kernel cmdline)"
    else
        iommu_status="✅ AMD IOMMU: DISABLED (amd_iommu=on NOT found in kernel cmdline)"
    fi
else
    # Unknown or other vendor
    if echo "$cmdline" | grep -q -E "intel_iommu=on|amd_iommu=on"; then
        iommu_status="❌ IOMMU: ENABLED (found in kernel cmdline)"
    else
        iommu_status="✅ IOMMU: DISABLED (not found in kernel cmdline)"
    fi
fi

echo "$iommu_status"

echo ""
echo ""

# ============================================================================
# Part 2: Check PCI ACS (Access Control Services) on all PCI devices
# ============================================================================
echo "2. PCI ACS (Access Control Services) Status"
echo "-----------------------------------------------------------------------"

# Find all PCI addresses
pci_addresses=$(lspci | cut -d' ' -f1)

if [ -z "$pci_addresses" ]; then
    echo "❌ No PCI devices found"
    exit 1
fi

# Arrays to store devices with ACS
declare -a acs_enabled_devices
declare -a acs_disabled_devices
declare -a acs_capable_devices

echo "Scanning PCI devices for ACS capability..."
echo ""

for addr in $pci_addresses; do
    # Get full device info
    device_info=$(lspci -s "$addr" 2>/dev/null)
    
    # Check if device has ACS capability
    acs_info=$(lspci -vvv -s "$addr" 2>/dev/null | grep -A 10 "Access Control Services")
    
    if [ -n "$acs_info" ]; then
        # Device has ACS capability
        acs_capable_devices+=("$addr")
        
        # Check ACSCtl to see if ACS is enabled
        acsctl=$(echo "$acs_info" | grep "ACSCtl:")
        
        if [ -n "$acsctl" ]; then
            # Check if SrcValid, TransBlk, ReqRedir, CmpltRedir, UpstreamFwd, EgressCtrl are enabled
            # ACS is considered "enabled" if any of these flags are set with a '+'
            if echo "$acsctl" | grep -q "+"; then
                acs_enabled_devices+=("$addr|$device_info")
            else
                acs_disabled_devices+=("$addr|$device_info")
            fi
        fi
    fi
done

# Display results
echo "Summary:"
echo "  Total PCI devices scanned: $(echo "$pci_addresses" | wc -l)"
echo "  Devices with ACS capability: ${#acs_capable_devices[@]}"
echo "  Devices with ACS ENABLED: ${#acs_enabled_devices[@]}"
echo "  Devices with ACS DISABLED: ${#acs_disabled_devices[@]}"
echo ""

# Overall status: Good if no devices have ACS enabled
if [ ${#acs_enabled_devices[@]} -eq 0 ]; then
    echo "✅ PCI ACS Status: No devices have ACS enabled (GOOD)"
else
    echo "❌ PCI ACS Status: ${#acs_enabled_devices[@]} device(s) have ACS enabled"
fi
echo ""

if [ ${#acs_enabled_devices[@]} -gt 0 ]; then
    echo "Devices with ACS ENABLED:"
    echo "-----------------------------------------------------------------------"
    for device in "${acs_enabled_devices[@]}"; do
        addr=$(echo "$device" | cut -d'|' -f1)
        info=$(echo "$device" | cut -d'|' -f2-)
        echo "  ❌ $addr: $info"
        
        # Show detailed ACS control bits
        acsctl=$(lspci -vvv -s "$addr" 2>/dev/null | grep "ACSCtl:")
        if [ -n "$acsctl" ]; then
            echo "     $acsctl"
        fi
    done
    echo ""
fi

echo "======================================================================="
echo "Scan Complete"
echo "======================================================================="

