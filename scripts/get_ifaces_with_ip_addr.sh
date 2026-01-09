#!/bin/bash

# 1. Print Header
printf "%-18s | %-10s | %-12s | %-10s | %s\n" "Logical Interface" "HCA ID" "PHY Port" "Status" "IP Address"
echo "========================================================================================================="

# 2. Loop through interfaces that have a Global IP address
ip -br addr show scope global | awk '$3 != ""' | while read iface status ip; do
    
    # Reset variables
    phys_match=""
    hca_id=""
    
    # Get the HCA ID for this interface (if it exists)
    # The IB device is found at: /sys/class/net/<iface>/device/infiniband/<hca_id>
    iface_path="/sys/class/net/$iface"
    if [ -L "$iface_path/device" ]; then
        ib_device_path="$iface_path/device/infiniband"
        if [ -d "$ib_device_path" ]; then
            hca_id=$(ls "$ib_device_path" 2>/dev/null | head -n 1)
        fi
    fi
    
    # 3. Determine PHY Port
    # Check if this interface ITSELF is a physical interface (has device symlink)
    is_physical=false
    if [ -L "$iface_path/device" ]; then
        is_physical=true
    fi

    if [ "$is_physical" = true ]; then
        # This interface is a physical interface itself
        phys_match="(Physical)"
    else
        # This is a virtual interface - look for a physical backing port
        # by finding another interface that:
        #   a) Is NOT the interface we are currently checking
        #   b) Has a physical 'device' symlink (meaning it's real hardware)
        #   c) Shares the exact same MAC address
        
        iface_mac=$(cat /sys/class/net/$iface/address 2>/dev/null)
        
        if [ ! -z "$iface_mac" ]; then
            for syspath in /sys/class/net/*; do
                cand_name=$(basename "$syspath")
                
                # Skip itself
                if [ "$cand_name" == "$iface" ]; then continue; fi
                
                # Check if this candidate is real hardware (has /device folder)
                if [ -L "$syspath/device" ]; then
                    cand_mac=$(cat "$syspath/address" 2>/dev/null)
                    
                    if [ "$cand_mac" == "$iface_mac" ]; then
                        phys_match="$cand_name"
                        break # Found it, stop searching
                    fi
                fi
            done
        fi

        # If no physical backing found, mark as purely virtual
        if [ -z "$phys_match" ]; then
            phys_match="(Virtual)"
        fi
    fi

    # 4. Print the row
    printf "%-18s | %-10s | %-12s | %-10s | %s\n" "$iface" "$hca_id" "$phys_match" "$status" "$ip"
done
