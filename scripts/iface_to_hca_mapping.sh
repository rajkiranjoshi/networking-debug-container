#!/bin/bash

# Arrays to store interface -> HCA mappings
declare -A iface_hca_map
declare -a iface_list

# 1. Loop through all network interfaces
for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")

    # Skip loopback or virtual-only interfaces (must have a physical device link)
    if [ ! -L "$iface_path/device" ]; then continue; fi

    # Check if this interface has an associated InfiniBand device
    # The IB device is found at: /sys/class/net/<iface>/device/infiniband/<hca_id>
    ib_device_path="$iface_path/device/infiniband"
    
    if [ -d "$ib_device_path" ]; then
        # Get the HCA/IB device name (e.g., mlx5_0, mlx5_17)
        hca_id=$(ls "$ib_device_path" 2>/dev/null | head -n 1)
        
        if [ ! -z "$hca_id" ]; then
            iface_hca_map["$iface"]="$hca_id"
            iface_list+=("$iface")
        fi
    fi
done

# 2. Print Header
printf "%-15s | %s\n" "PHY iface" "HCA ID"
echo "======================================="

# 3. Sort the interfaces naturally and print
if [ ${#iface_list[@]} -eq 0 ]; then
    echo "No InfiniBand interfaces found."
    exit 0
fi

IFS=$'\n' sorted_ifaces=($(sort -V <<<"${iface_list[*]}"))
unset IFS

for iface in "${sorted_ifaces[@]}"; do
    hca_id="${iface_hca_map[$iface]}"
    printf "%-15s | %s\n" "$iface" "$hca_id"
done

