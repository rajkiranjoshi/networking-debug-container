#!/bin/bash
set -e

echo "=== Removing apt-installed perftest package (if present) ==="
apt-get remove -y perftest || echo "perftest package not installed, continuing..."

echo "=== Installing runtime dependencies ==="
apt-get update
apt-get install -y --no-install-recommends \
    libibverbs1 \
    librdmacm1 \
    libibumad3 \
    libpci3

echo "=== Installing build dependencies ==="
apt-get install -y --no-install-recommends \
    git \
    build-essential \
    autoconf \
    automake \
    libtool \
    libpci-dev \
    libibverbs-dev \
    librdmacm-dev \
    pkg-config

echo "=== Cloning perftest repository ==="
git clone https://github.com/linux-rdma/perftest.git /tmp/perftest
cd /tmp/perftest

echo "=== Checking out release tag 25.10.0-0.128 ==="
git checkout tags/25.10.0-0.128
echo "✓ Using perftest version: $(git describe --tags 2>/dev/null || git rev-parse --short HEAD)"

echo "=== Running autogen.sh ==="
./autogen.sh

echo "=== Configuring perftest with CUDA support ==="
# CUDA support is auto-detected if /usr/local/cuda/include/cuda.h exists
if [ -f /usr/local/cuda/include/cuda.h ]; then
    echo "✓ CUDA headers found at /usr/local/cuda/include/cuda.h"
    export CUDA_H_PATH=/usr/local/cuda/include/cuda.h
    # Enable cudart for full CUDA runtime features (GPUDirect RDMA, etc.)
    ./configure --prefix=/usr --enable-cudart
    echo "✓ CUDA support enabled with cudart"
else
    echo "⚠ CUDA headers not found, building without CUDA support"
    ./configure --prefix=/usr
fi
echo "Configure completed successfully"

echo "=== Building perftest ==="
make -j$(nproc)
echo "Build completed successfully"

echo "=== Installing perftest binaries ==="
make install
echo "Install completed"

echo "=== Verifying installation ==="
if [ -f /usr/bin/ib_write_bw ]; then
    echo "✓ ib_write_bw installed at /usr/bin/ib_write_bw"
    ls -lh /usr/bin/ib_*
else
    echo "✗ ERROR: ib_write_bw not found in /usr/bin"
    echo "Searching for binaries..."
    find /usr -name "ib_write_bw" 2>/dev/null || echo "Not found in /usr"
    find /tmp/perftest -name "ib_write_bw" 2>/dev/null || echo "Not found in build directory"
    exit 1
fi

# Test the binary
echo "=== Testing ib_write_bw binary ==="
ib_write_bw --version || echo "Note: ib_write_bw --version failed (may be normal)"
ldd /usr/bin/ib_write_bw | grep -i "not found" && echo "ERROR: Missing libraries!" && exit 1

echo "=== Cleaning up ==="
cd /
rm -rf /tmp/perftest

# Keep all build tools and packages installed for development/debugging
# Only clean up temporary files and apt cache
rm -rf /var/lib/apt/lists/*

echo "Note: Kept all build tools and MLNX OFED packages installed"

echo "=== Final verification after cleanup ==="
if [ -f /usr/bin/ib_write_bw ]; then
    echo "✓ Binaries still present after cleanup"
    ldd /usr/bin/ib_write_bw | grep -i "not found" && echo "ERROR: Missing libraries after cleanup!" && exit 1
    echo "✓ All libraries present"
else
    echo "✗ ERROR: Binaries disappeared after cleanup!"
    exit 1
fi

echo "=== perftest with CUDA support installed successfully! ==="

