#!/bin/bash

# Arrays to store data
declare -A vf_map
declare -a pf_list
declare -A pf_device_path  # Track PF's device path to find orphan VFs

# 1. Loop through all network interfaces to classify them
for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")

    # Skip loopback or virtual-only interfaces (must have a physical device link)
    if [ ! -L "$iface_path/device" ]; then continue; fi

    # Check if this interface is a Virtual Function (VF)
    if [ -L "$iface_path/device/physfn" ]; then
        # It is a VF. Find its parent.
        parent=$(ls "$iface_path/device/physfn/net/" 2>/dev/null | head -n 1)
        if [ ! -z "$parent" ]; then
            vf_map["$parent"]="${vf_map["$parent"]} $iface"
        fi
    else
        # It is a Physical Function (PF)
        # We add it to our list of physical ports
        pf_list+=("$iface")
        # Store the device path for later VF discovery
        pf_device_path["$iface"]="$iface_path/device"
    fi
done

# 2. Look for orphan VFs (VFs without network interfaces) under each PF
for pf in "${pf_list[@]}"; do
    device_path="${pf_device_path[$pf]}"
    if [ -z "$device_path" ]; then continue; fi
    
    # Check each virtfn* symlink (these point to VF PCI devices)
    for virtfn_link in "$device_path"/virtfn*; do
        [ -L "$virtfn_link" ] || continue
        
        # Check if this VF has a network interface
        vf_net_path="$virtfn_link/net"
        if [ -d "$vf_net_path" ]; then
            vf_iface=$(ls "$vf_net_path" 2>/dev/null | head -n 1)
            if [ ! -z "$vf_iface" ]; then
                # This VF has a network interface, already captured in step 1
                continue
            fi
        fi
        
        # This VF has no network interface - add it as <unknown>
        vf_map["$pf"]="${vf_map["$pf"]} <unknown>"
    done
done

# 3. Print Header
printf "%-10s | %s\n" "PHY Port" "Mapped SR-IOV VFs"
echo "======================================================="

# 4. Sort the Physical Ports naturally (p0..p2..p10) and print
IFS=$'\n' sorted_pfs=($(sort -V <<<"${pf_list[*]}"))
unset IFS

for pf in "${sorted_pfs[@]}"; do
    # Get the list of VFs for this PF (if any)
    vfs="${vf_map[$pf]}"
    
    # If VFs exist, sort them for display; otherwise leave blank
    # Put <unknown> entries at the end
    if [ ! -z "$vfs" ]; then
        known_vfs=$(echo "$vfs" | tr ' ' '\n' | grep -v '^<unknown>$' | sort -V | tr '\n' ' ')
        unknown_vfs=$(echo "$vfs" | tr ' ' '\n' | grep '^<unknown>$' | tr '\n' ' ')
        sorted_vfs="${known_vfs}${unknown_vfs}"
        printf "%-10s | %s\n" "$pf" "$sorted_vfs"
    else
        printf "%-10s | %s\n" "$pf" "(None)"
    fi
done
