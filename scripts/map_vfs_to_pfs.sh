#!/bin/bash

# Arrays to store data
declare -A vf_map
declare -a pf_list

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
    fi
done

# 2. Print Header
printf "%-10s | %s\n" "PHY Port" "Mapped SR-IOV VFs"
echo "======================================================="

# 3. Sort the Physical Ports naturally (p0..p2..p10) and print
IFS=$'\n' sorted_pfs=($(sort -V <<<"${pf_list[*]}"))
unset IFS

for pf in "${sorted_pfs[@]}"; do
    # Get the list of VFs for this PF (if any)
    vfs="${vf_map[$pf]}"
    
    # If VFs exist, sort them for display; otherwise leave blank
    if [ ! -z "$vfs" ]; then
        sorted_vfs=$(echo "$vfs" | tr ' ' '\n' | sort -V | tr '\n' ' ')
        printf "%-10s | %s\n" "$pf" "$sorted_vfs"
    else
        printf "%-10s | %s\n" "$pf" "(None)"
    fi
done
