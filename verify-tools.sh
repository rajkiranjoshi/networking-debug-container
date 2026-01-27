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

# Detect available GPUs on the host system
HAS_NVIDIA_GPU=false
HAS_AMD_GPU=false
NVIDIA_DOCKER_FLAGS=""
AMD_DOCKER_FLAGS=""

# Check for NVIDIA GPU (nvidia-smi available and working)
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    HAS_NVIDIA_GPU=true
    NVIDIA_DOCKER_FLAGS="--gpus=all"
    echo -e "${GREEN}✓${NC} NVIDIA GPU detected on host"
fi

# Check for AMD GPU (/dev/kfd and /dev/dri exist)
if [ -e /dev/kfd ] && [ -d /dev/dri ]; then
    HAS_AMD_GPU=true
    AMD_DOCKER_FLAGS="--device=/dev/kfd --device=/dev/dri --group-add video"
    echo -e "${GREEN}✓${NC} AMD GPU detected on host"
fi

if ! $HAS_NVIDIA_GPU && ! $HAS_AMD_GPU; then
    echo -e "${YELLOW}⚠${NC} No GPU detected on host (GPU-specific tests will be skipped)"
fi
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

# Test GPU-compiled perftest binaries (CUDA + ROCm) - Table format
echo -e "${BLUE}=== GPU-Compiled Perftest Tools (CUDA + ROCm) ===${NC}"
echo ""

PERFTEST_TOOLS=(
    "ib_write_bw:Write BW"
    "ib_read_bw:Read BW"
    "ib_send_bw:Send BW"
    "ib_write_lat:Write Lat"
    "ib_read_lat:Read Lat"
    "ib_send_lat:Send Lat"
    "ib_atomic_bw:Atomic BW"
    "ib_atomic_lat:Atomic Lat"
)

# Print table header
echo "  Tool            Available    Dependencies    CUDA-enabled    ROCm-enabled"
echo "  --------------- ------------ --------------- --------------- ---------------"

for tool in "${PERFTEST_TOOLS[@]}"; do
    IFS=':' read -r cmd desc <<< "$tool"
    
    # Check if command exists
    if docker run --rm "$IMAGE_TAG" which "$cmd" &>/dev/null; then
        STATUS="${GREEN}✓${NC}"
        ((PASSED++))
        
        # Check binary location
        BIN_PATH=$(docker run --rm "$IMAGE_TAG" which "$cmd" 2>/dev/null)
        if [[ "$BIN_PATH" != "/usr/local/bin/"* ]]; then
            ((WARNINGS++))
        fi
        
        # Check library dependencies
        MISSING_DEPS=$(docker run --rm "$IMAGE_TAG" ldd "$BIN_PATH" 2>/dev/null | grep "not found")
        if [ -z "$MISSING_DEPS" ]; then
            DEPS="${GREEN}✓${NC}"
        else
            DEPS="${RED}✗${NC}"
            ((WARNINGS++))
        fi
        
        # Get help output once for both checks
        HELP_OUTPUT=$(docker run --rm "$IMAGE_TAG" "$cmd" --help 2>&1)
        
        # Check CUDA support
        if echo "$HELP_OUTPUT" | grep -qiE "(--use_cuda|use_cuda_bus_id)"; then
            CUDA="${GREEN}✓${NC}"
        else
            CUDA="${RED}✗${NC}"
            ((WARNINGS++))
        fi
        
        # Check ROCm support
        if echo "$HELP_OUTPUT" | grep -qiE "(--use_rocm|rocm_device|use_rocm_bus_id)"; then
            ROCM="${GREEN}✓${NC}"
        else
            ROCM="${RED}✗${NC}"
            ((WARNINGS++))
        fi
    else
        STATUS="${RED}✗${NC}"
        DEPS="-"
        CUDA="-"
        ROCM="-"
        ((FAILED++))
    fi
    
    echo -e "  $(printf '%-15s' "$cmd") $STATUS            $DEPS               $CUDA               $ROCM"
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
if $HAS_NVIDIA_GPU; then
    echo -n "Checking nvidia-smi (with GPU access)... "
    if docker run --rm $NVIDIA_DOCKER_FLAGS "$IMAGE_TAG" nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null; then
        GPU_NAME=$(docker run --rm $NVIDIA_DOCKER_FLAGS "$IMAGE_TAG" nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        echo -e "${GREEN}✓${NC} NVIDIA System Management Interface (nvidia-smi)"
        echo "    GPU detected: $GPU_NAME"
        ((PASSED++))
    else
        echo -e "${YELLOW}⚠${NC} NVIDIA System Management Interface (nvidia-smi)"
        echo "    Could not access GPU from container"
        ((WARNINGS++))
    fi
else
    echo -e "${YELLOW}⚠${NC} nvidia-smi check skipped (no NVIDIA GPU on host)"
fi
echo ""

# Test ROCm runtime
echo -e "${BLUE}=== ROCm Runtime ===${NC}"
ROCM_LIBS=(
    "/opt/rocm/lib/libamdhip64.so:AMD HIP Runtime Library"
)

for lib in "${ROCM_LIBS[@]}"; do
    IFS=':' read -r file desc <<< "$lib"
    
    # Check for library (may have version suffix)
    if docker run --rm "$IMAGE_TAG" sh -c "ls ${file}* 2>/dev/null | head -1" | grep -q .; then
        FOUND_LIB=$(docker run --rm "$IMAGE_TAG" sh -c "ls ${file}* 2>/dev/null | head -1")
        echo -e "${GREEN}✓${NC} $desc ($FOUND_LIB)"
        ((PASSED++))
    else
        echo -e "${RED}✗${NC} $desc ($file) - NOT FOUND"
        ((FAILED++))
    fi
done

# Check for amd-smi (AMD System Management Interface - modern AMD GPU monitoring tool)
echo -n "Checking amd-smi... "
if docker run --rm "$IMAGE_TAG" which amd-smi &>/dev/null; then
    echo -e "${GREEN}✓${NC} AMD System Management Interface (amd-smi)"
    ((PASSED++))
    # Show version
    AMD_SMI_VERSION=$(docker run --rm "$IMAGE_TAG" amd-smi version 2>/dev/null | grep -E "^[0-9]|AMDSMI|Tool" | head -1)
    if [ -n "$AMD_SMI_VERSION" ]; then
        echo "    Version: $AMD_SMI_VERSION"
    fi
    # Try to query GPUs if AMD GPU is available on host
    if $HAS_AMD_GPU; then
        if docker run --rm $AMD_DOCKER_FLAGS "$IMAGE_TAG" amd-smi list &>/dev/null 2>&1; then
            GPU_INFO=$(docker run --rm $AMD_DOCKER_FLAGS "$IMAGE_TAG" amd-smi list 2>/dev/null | grep -E "GPU|card|Card")
            if [ -n "$GPU_INFO" ]; then
                GPU_COUNT=$(echo "$GPU_INFO" | wc -l)
                echo "    AMD GPU(s) detected: $GPU_COUNT"
                echo "$GPU_INFO" | while read -r line; do
                    echo "      $line"
                done
            fi
        else
            echo "    (Could not query AMD GPU from container)"
        fi
    else
        echo "    (No AMD GPU on host - GPU query skipped)"
    fi
else
    echo -e "${RED}✗${NC} AMD System Management Interface (amd-smi) - NOT FOUND"
    ((FAILED++))
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
    echo "  1. Test interactively:"
    if $HAS_NVIDIA_GPU && $HAS_AMD_GPU; then
        echo "     # For NVIDIA GPU:"
        echo "     docker run --rm -it $NVIDIA_DOCKER_FLAGS --network=host $IMAGE_TAG"
        echo "     # For AMD GPU:"
        echo "     docker run --rm -it $AMD_DOCKER_FLAGS --network=host $IMAGE_TAG"
    elif $HAS_NVIDIA_GPU; then
        echo "     docker run --rm -it $NVIDIA_DOCKER_FLAGS --network=host $IMAGE_TAG"
    elif $HAS_AMD_GPU; then
        echo "     docker run --rm -it $AMD_DOCKER_FLAGS --network=host $IMAGE_TAG"
    else
        echo "     # For NVIDIA GPU systems:"
        echo "     docker run --rm -it --gpus=all --network=host $IMAGE_TAG"
        echo "     # For AMD GPU systems:"
        echo "     docker run --rm -it --device=/dev/kfd --device=/dev/dri --group-add video --network=host $IMAGE_TAG"
    fi
    echo "  2. Run your specific workloads"
    echo "  3. Deploy if everything works"
    exit 0
else
    echo -e "${RED}✗ Verification failed! Missing $FAILED critical tools.${NC}"
    echo "Please review the Dockerfile and ensure all necessary packages are installed."
    exit 1
fi




