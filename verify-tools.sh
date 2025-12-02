#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

IMAGE_TAG=${1:-networking-debug:optimized}

if ! docker image inspect "$IMAGE_TAG" &>/dev/null; then
    echo -e "${RED}✗ Image not found: $IMAGE_TAG${NC}"
    echo "Usage: $0 [image-tag]"
    exit 1
fi

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Verifying Tools in: $IMAGE_TAG${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

PASSED=0
FAILED=0
WARNINGS=0

check_command() {
    local cmd=$1
    local description=$2
    
    if docker run --rm "$IMAGE_TAG" which "$cmd" &>/dev/null; then
        echo -e "${GREEN}✓${NC} $description ($cmd)"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $description ($cmd) - NOT FOUND"
        ((FAILED++))
        return 1
    fi
}

check_file() {
    local file=$1
    local description=$2
    
    if docker run --rm "$IMAGE_TAG" test -f "$file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $description ($file)"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $description ($file) - NOT FOUND"
        ((FAILED++))
        return 1
    fi
}

check_library_deps() {
    local binary=$1
    local description=$2
    
    echo -n "  Checking dependencies for $description... "
    local missing=$(docker run --rm "$IMAGE_TAG" ldd "$binary" 2>/dev/null | grep "not found")
    
    if [ -z "$missing" ]; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}MISSING LIBRARIES:${NC}"
        echo "$missing"
        ((WARNINGS++))
        return 1
    fi
}

check_perftest_cuda_support() {
    local cmd=$1
    local description=$2
    
    echo -n "  Checking CUDA support for $description... "
    local help_output=$(docker run --rm "$IMAGE_TAG" "$cmd" --help 2>&1)
    
    # Check for CUDA-related options in help output
    if echo "$help_output" | grep -qiE "(--use_cuda|CUDA|--cuda_device|use_cuda_bus_id|GPU)"; then
        echo -e "${GREEN}CUDA ENABLED${NC}"
        # Show specific CUDA options available
        local cuda_opts=$(echo "$help_output" | grep -iE "(cuda|gpu)" | head -3)
        if [ -n "$cuda_opts" ]; then
            echo "    CUDA options found:"
            echo "$cuda_opts" | while read -r line; do
                echo "      $line"
            done
        fi
        return 0
    else
        echo -e "${RED}NO CUDA SUPPORT${NC}"
        echo -e "    ${YELLOW}⚠ Tool appears to be compiled without CUDA support${NC}"
        ((WARNINGS++))
        return 1
    fi
}

# Test CUDA-compiled perftest binaries
echo -e "${BLUE}=== CUDA-Compiled Perftest Tools ===${NC}"
PERFTEST_TOOLS=(
    "ib_write_bw:RDMA Write Bandwidth Test"
    "ib_read_bw:RDMA Read Bandwidth Test"
    "ib_send_bw:RDMA Send Bandwidth Test"
    "ib_write_lat:RDMA Write Latency Test"
    "ib_read_lat:RDMA Read Latency Test"
    "ib_send_lat:RDMA Send Latency Test"
    "ib_atomic_bw:RDMA Atomic Bandwidth Test"
    "ib_atomic_lat:RDMA Atomic Latency Test"
)

for tool in "${PERFTEST_TOOLS[@]}"; do
    IFS=':' read -r cmd desc <<< "$tool"
    if check_command "$cmd" "$desc"; then
        # Check if binary location is correct (should be in /usr/local/bin for CUDA version)
        BIN_PATH=$(docker run --rm "$IMAGE_TAG" which "$cmd" 2>/dev/null)
        if [[ "$BIN_PATH" == "/usr/local/bin/"* ]]; then
            echo "    Location: $BIN_PATH (CUDA-compiled)"
        else
            echo -e "    ${YELLOW}⚠ Location: $BIN_PATH (might be apt version)${NC}"
            ((WARNINGS++))
        fi
        # Check library dependencies
        check_library_deps "$BIN_PATH" "$cmd"
        # Check if compiled with CUDA support
        check_perftest_cuda_support "$cmd" "$desc"
    fi
done
echo ""

# Test OFED tools
echo -e "${BLUE}=== Mellanox OFED Tools ===${NC}"
OFED_TOOLS=(
    "ibv_devinfo:InfiniBand Device Info"
    "ibv_devices:List InfiniBand Devices"
    "show_gids:Show GIDs"
    "ibdev2netdev:Map IB Devices to Network Devices"
    "ibstat:InfiniBand Status"
    "ibstatus:InfiniBand Status (alternative)"
    "ibnetdiscover:InfiniBand Network Discovery"
    "ibhosts:List InfiniBand Hosts"
    "ibswitches:List InfiniBand Switches"
    "iblinkinfo:InfiniBand Link Info"
    "perfquery:Performance Query"
    "mst:Mellanox Software Tools"
    "mstconfig:MST Configuration Tool"
    "mstflint:MST Firmware Update Tool"
    "mlxlink:Mellanox Link Tool"
    "mlxcables:Mellanox Cable Info"
)

for tool in "${OFED_TOOLS[@]}"; do
    IFS=':' read -r cmd desc <<< "$tool"
    check_command "$cmd" "$desc"
done
echo ""

# Test system utilities
echo -e "${BLUE}=== System Utilities ===${NC}"
SYSTEM_TOOLS=(
    "ip:IP Address Management"
    "lshw:Hardware Lister"
    "lspci:PCI Device Lister"
    "ethtool:Ethernet Tool"
    "ifconfig:Interface Configuration"
    "htop:Process Monitor"
    "vim:Text Editor"
    "less:File Pager"
    "iperf:Network Performance Tool"
    "iperf3:Network Performance Tool (v3)"
    "tcpdump:Packet Capture"
)

for tool in "${SYSTEM_TOOLS[@]}"; do
    IFS=':' read -r cmd desc <<< "$tool"
    check_command "$cmd" "$desc"
done
echo ""

# Test CUDA runtime
echo -e "${BLUE}=== CUDA Runtime ===${NC}"
CUDA_LIBS=(
    "/usr/local/cuda/lib64/libcudart.so:CUDA Runtime Library"
    "/usr/local/cuda/include/cuda.h:CUDA Header File"
)

for lib in "${CUDA_LIBS[@]}"; do
    IFS=':' read -r file desc <<< "$lib"
    
    # Try multiple common CUDA paths
    found=0
    for version_path in "$file" "/usr/local/cuda-12.8/lib64/libcudart.so" "/usr/local/cuda-12.8/include/cuda.h"; do
        if docker run --rm "$IMAGE_TAG" test -f "$version_path" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} $desc ($version_path)"
            ((PASSED++))
            found=1
            break
        fi
    done
    
    if [ $found -eq 0 ]; then
        # For runtime-only images, cuda.h might not be present (that's OK)
        if [[ "$file" == *"cuda.h"* ]]; then
            echo -e "${YELLOW}⚠${NC} $desc - Not found (OK for runtime-only images)"
            ((WARNINGS++))
        else
            echo -e "${RED}✗${NC} $desc - NOT FOUND"
            ((FAILED++))
        fi
    fi
done

# Check for nvidia-smi (requires --gpus=all to access NVIDIA driver)
echo -n "Checking nvidia-smi (with GPU access)... "
if docker run --rm --gpus=all "$IMAGE_TAG" nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null; then
    GPU_NAME=$(docker run --rm --gpus=all "$IMAGE_TAG" nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    echo -e "${GREEN}✓${NC} NVIDIA System Management Interface (nvidia-smi)"
    echo "    GPU detected: $GPU_NAME"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠${NC} NVIDIA System Management Interface (nvidia-smi)"
    echo "    Could not access GPU (host may not have NVIDIA driver or GPU)"
    ((WARNINGS++))
fi
echo ""

# Test RDMA libraries
echo -e "${BLUE}=== RDMA Runtime Libraries ===${NC}"
RDMA_LIBS=(
    "/usr/lib/x86_64-linux-gnu/libibverbs.so.1:IB Verbs Library"
    "/usr/lib/x86_64-linux-gnu/librdmacm.so.1:RDMA CM Library"
)

for lib in "${RDMA_LIBS[@]}"; do
    IFS=':' read -r file desc <<< "$lib"
    check_file "$file" "$desc"
done
echo ""

# Test scripts directory
echo -e "${BLUE}=== Custom Scripts ===${NC}"
if docker run --rm "$IMAGE_TAG" test -d /root/scripts 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Scripts directory exists"
    ((PASSED++))
    docker run --rm "$IMAGE_TAG" ls -la /root/scripts/
else
    echo -e "${RED}✗${NC} Scripts directory not found"
    ((FAILED++))
fi
echo ""

# Summary
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Verification Summary${NC}"
echo -e "${BLUE}============================================${NC}"
echo -e "Passed:   ${GREEN}$PASSED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "Failed:   ${RED}$FAILED${NC}"
fi
if [ $WARNINGS -gt 0 ]; then
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
fi
echo ""

# Image size
SIZE=$(docker image inspect "$IMAGE_TAG" --format='{{.Size}}' | awk '{print $1/1024/1024/1024}')
echo -e "Image size: ${GREEN}${SIZE} GB${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All critical tools verified successfully!${NC}"
    
    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠ Some warnings detected (review above)${NC}"
    fi
    
    echo ""
    echo "Next steps:"
    echo "  1. Test interactively: docker run --rm -it --gpus=all --network=host $IMAGE_TAG"
    echo "  2. Run your specific workloads"
    echo "  3. Deploy if everything works"
    exit 0
else
    echo -e "${RED}✗ Verification failed! Missing $FAILED critical tools.${NC}"
    echo "Please review the Dockerfile and ensure all necessary packages are installed."
    exit 1
fi




