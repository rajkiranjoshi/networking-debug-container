#!/bin/bash

# Arrays to store interface -> HCA mappings
declare -A iface_hca_map
declare -A iface_sriov_map
declare -A iface_orphan_map  # Track HCAs without a network interface
declare -a iface_list
# Track which HCA IDs have been seen (to find orphan HCAs without network interfaces)
declare -A seen_hca_ids

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
            seen_hca_ids["$hca_id"]=1
            
            # Check if this is an SR-IOV Virtual Function (VF)
            # VFs have a 'physfn' symlink pointing to their parent Physical Function
            if [ -L "$iface_path/device/physfn" ]; then
                iface_sriov_map["$iface"]=1
            else
                iface_sriov_map["$iface"]=0
            fi
        fi
    fi
done

# 2. Look for orphan HCA devices that don't have a network interface
# This catches SR-IOV VFs that exist but have no Ethernet interface assigned
for hca_path in /sys/class/infiniband/*; do
    hca_id=$(basename "$hca_path")
    
    # Skip if we already found this HCA via a network interface
    if [ "${seen_hca_ids[$hca_id]}" == "1" ]; then continue; fi
    
    # Check if this HCA has a physical device link
    if [ ! -L "$hca_path/device" ]; then continue; fi
    
    # Use a placeholder name for the interface
    placeholder="<unknown>_$hca_id"
    iface_hca_map["$placeholder"]="$hca_id"
    iface_list+=("$placeholder")
    
    # Check if this is an SR-IOV Virtual Function (VF)
    if [ -L "$hca_path/device/physfn" ]; then
        iface_sriov_map["$placeholder"]=1
    else
        iface_sriov_map["$placeholder"]=0
    fi
    
    # Mark this as an orphan HCA (no network interface)
    iface_orphan_map["$placeholder"]=1
done

# 3. Print Header
printf "%-15s | %s\n" "PHY iface" "HCA ID"
echo "======================================="

# 4. Sort the interfaces naturally and print
if [ ${#iface_list[@]} -eq 0 ]; then
    echo "No InfiniBand interfaces found."
    exit 0
fi

IFS=$'\n' sorted_ifaces=($(sort -V <<<"${iface_list[*]}"))
unset IFS

for iface in "${sorted_ifaces[@]}"; do
    hca_id="${iface_hca_map[$iface]}"
    
    # Determine display name: show <unknown> for orphan HCAs
    if [ "${iface_orphan_map[$iface]}" == "1" ]; then
        display_name="<unknown>"
    else
        display_name="$iface"
    fi
    
    # Mark SR-IOV VFs with an asterisk
    if [ "${iface_sriov_map[$iface]}" -eq 1 ]; then
        printf "%-15s | %s *\n" "$display_name" "$hca_id"
    else
        printf "%-15s | %s\n" "$display_name" "$hca_id"
    fi
done

echo ""
echo "* = SR-IOV Virtual Function (VF)"

