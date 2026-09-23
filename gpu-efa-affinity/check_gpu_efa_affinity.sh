#!/bin/bash

# Check GPU-to-EFA NIC PCIe affinity for devices allocated to this pod.
# Reports whether GPUs and EFA NICs share the same PCIe switch (are topologically aligned).
#
# Run inside a pod that has both GPU and EFA NIC resources:
#   bash check_gpu_efa_affinity.sh

set -e

if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' BOLD='' NC=''
fi

get_pcie_switch() {
    local pci_addr="$1"
    local dev_path
    dev_path=$(readlink -f "/sys/bus/pci/devices/$pci_addr" 2>/dev/null) || return
    local parent_port
    parent_port=$(basename "$(dirname "$dev_path")")
    # Strip the function number (.X) to get the switch identity (bus:device).
    # E.g. GPU behind 0000:79:01.4 and NICs behind 0000:79:01.0 are on the same switch 0000:79:01.
    echo "${parent_port%.*}"
}

get_numa_node() {
    local pci_addr="$1"
    cat "/sys/bus/pci/devices/$pci_addr/numa_node" 2>/dev/null || echo "-1"
}

parse_pci_addr() {
    local addr="$1"
    # Sysfs uses lowercase hex; nvidia-smi may return uppercase (e.g. CA:00.0)
    addr=$(echo "$addr" | tr '[:upper:]' '[:lower:]')
    if [[ "$addr" =~ ^[0-9a-f]{4}: ]]; then
        echo "$addr"
    else
        echo "0000:$addr"
    fi
}

short_pci() {
    echo "$1" | sed -E 's/^0000://'
}

# Collect GPUs
declare -a gpu_pci=()
declare -a gpu_idx=()

if command -v nvidia-smi &>/dev/null; then
    while IFS=',' read -r idx pci; do
        pci=$(echo "$pci" | tr -d ' ' | sed 's/^0000//')
        pci=$(parse_pci_addr "$pci")
        gpu_idx+=("$idx")
        gpu_pci+=("$pci")
    done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null)
fi

if [ ${#gpu_pci[@]} -eq 0 ]; then
    echo "No GPUs found. Run this inside a pod with GPU resources."
    exit 1
fi

# Collect EFA NICs actually allocated to this pod.
# ibv_devices lists only devices whose uverbs char devices are present,
# which is exactly the set allocated by the EFA device plugin.
declare -A allocated_nics
if command -v ibv_devices &>/dev/null; then
    while read -r dev _; do
        [ -n "$dev" ] && allocated_nics["$dev"]=1
    done < <(ibv_devices 2>/dev/null | tail -n +3)
fi

declare -a nic_name=()
declare -a nic_pci=()

for hca_path in /sys/class/infiniband/*; do
    [ ! -d "$hca_path" ] && continue
    name=$(basename "$hca_path")

    # If ibv_devices gave us a list, filter to only allocated devices
    if [ ${#allocated_nics[@]} -gt 0 ] && [ -z "${allocated_nics[$name]+_}" ]; then
        continue
    fi

    pci_link=$(readlink "$hca_path/device" 2>/dev/null) || continue
    pci=$(parse_pci_addr "$(basename "$pci_link")")
    nic_name+=("$name")
    nic_pci+=("$pci")
done

if [ ${#nic_name[@]} -eq 0 ]; then
    echo "No EFA/RDMA NICs found. Run this inside a pod with EFA resources."
    exit 1
fi

# Build switch maps
declare -A gpu_switch_map
for i in "${!gpu_pci[@]}"; do
    gpu_switch_map["${gpu_pci[$i]}"]=$(get_pcie_switch "${gpu_pci[$i]}")
done

declare -A nic_switch_map
for i in "${!nic_pci[@]}"; do
    nic_switch_map["${nic_pci[$i]}"]=$(get_pcie_switch "${nic_pci[$i]}")
done

# Group NICs by their PCIe switch
declare -A switch_to_nics
for i in "${!nic_pci[@]}"; do
    sw="${nic_switch_map[${nic_pci[$i]}]}"
    if [ -n "${switch_to_nics[$sw]}" ]; then
        switch_to_nics[$sw]="${switch_to_nics[$sw]} $i"
    else
        switch_to_nics[$sw]="$i"
    fi
done

aligned=0
misaligned=0
total_gpus=${#gpu_pci[@]}
total_nics=${#nic_pci[@]}

echo ""
echo -e "${BOLD}GPU-EFA PCIe Affinity Report${NC}"
echo -e "${BOLD}============================${NC}"
echo ""
echo "  GPUs allocated:     $total_gpus"
echo "  EFA NICs allocated: $total_nics"
echo "  Expected ratio:     1:4 ($(( total_gpus * 4 )) NICs expected)"
echo ""

if [ "$total_nics" -ne "$(( total_gpus * 4 ))" ]; then
    echo -e "  ${YELLOW}WARNING: NIC count ($total_nics) != 4 x GPU count ($total_gpus) = $(( total_gpus * 4 ))${NC}"
    echo ""
fi

printf "  %-6s  %-12s  %-14s  %-5s  %-10s  %s\n" "GPU" "GPU PCIe" "PCIe Switch" "NUMA" "Aligned" "EFA NICs on same switch"
printf "  %-6s  %-12s  %-14s  %-5s  %-10s  %s\n" "------" "------------" "--------------" "-----" "----------" "----------------------------"

for i in "${!gpu_pci[@]}"; do
    g_pci="${gpu_pci[$i]}"
    g_idx="${gpu_idx[$i]}"
    g_sw="${gpu_switch_map[$g_pci]}"
    g_numa=$(get_numa_node "$g_pci")

    matched_nics=""
    matched_count=0
    nic_indices="${switch_to_nics[$g_sw]}"
    if [ -n "$nic_indices" ]; then
        for ni in $nic_indices; do
            if [ -n "$matched_nics" ]; then
                matched_nics="$matched_nics, ${nic_name[$ni]}"
            else
                matched_nics="${nic_name[$ni]}"
            fi
            matched_count=$((matched_count + 1))
        done
    fi

    if [ "$matched_count" -eq 4 ]; then
        status="${GREEN}YES (4)${NC}  "
        aligned=$((aligned + 1))
    elif [ "$matched_count" -gt 0 ]; then
        status="${YELLOW}PARTIAL ($matched_count)${NC}"
        misaligned=$((misaligned + 1))
    else
        status="${RED}NO (0)${NC}   "
        misaligned=$((misaligned + 1))
    fi

    printf "  %-6s  %-12s  %-14s  %-5s  " "GPU $g_idx" "$(short_pci "$g_pci")" "$(short_pci "$g_sw")" "$g_numa"
    echo -e "$status  $matched_nics"
done

# Detect orphan NICs not aligned with any allocated GPU
orphan_nics=""
for i in "${!nic_pci[@]}"; do
    n_sw="${nic_switch_map[${nic_pci[$i]}]}"
    has_gpu=false
    for g in "${!gpu_pci[@]}"; do
        if [ "${gpu_switch_map[${gpu_pci[$g]}]}" = "$n_sw" ]; then
            has_gpu=true
            break
        fi
    done
    if ! $has_gpu; then
        orphan_nics="$orphan_nics ${nic_name[$i]}($(short_pci "${nic_pci[$i]}"))"
    fi
done

echo ""
if [ -n "$orphan_nics" ]; then
    echo -e "  ${YELLOW}Orphan NICs (no GPU on same PCIe switch):${NC}$orphan_nics"
    echo ""
fi

echo -e "${BOLD}Summary${NC}"
echo "  Aligned GPUs:    $aligned / $total_gpus"
echo "  Misaligned GPUs: $misaligned / $total_gpus"

if [ "$misaligned" -eq 0 ] && [ "$aligned" -eq "$total_gpus" ] && [ -z "$orphan_nics" ]; then
    echo -e "  ${GREEN}All GPUs and EFA NICs are PCIe-aligned.${NC}"
    exit 0
else
    echo -e "  ${RED}PCIe alignment issues detected.${NC}"
    exit 1
fi
