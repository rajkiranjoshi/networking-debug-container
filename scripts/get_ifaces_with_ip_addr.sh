#!/bin/bash

# 1. Print Header
printf "%-18s | %-12s | %-10s | %s\n" "Logical Interface" "PHY Port" "Status" "IP Address"
echo "========================================================================================="

# 2. Loop through interfaces that have a Global IP address
ip -br addr show scope global | awk '$3 != ""' | while read iface status ip; do
    
    # Reset variables
    phys_match=""
    
    # Get the MAC address of the current logical interface (e.g., br-ex)
    iface_mac=$(cat /sys/class/net/$iface/address 2>/dev/null)

    # 3. Find the physical backing port
    # We look for another interface that:
    #   a) Is NOT the interface we are currently checking
    #   b) Has a physical 'device' symlink (meaning it's real hardware)
    #   c) Shares the exact same MAC address
    
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

    # Formatting: If no physical match found, mark as purely virtual
    if [ -z "$phys_match" ]; then
        phys_match="(Virtual)"
    fi

    # 4. Print the row
    printf "%-18s | %-12s | %-10s | %s\n" "$iface" "$phys_match" "$status" "$ip"
done
