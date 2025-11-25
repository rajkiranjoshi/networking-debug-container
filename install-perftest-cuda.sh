#!/bin/bash
set -e

echo "Installing build dependencies..."
apt-get update
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

echo "Cloning perftest repository..."
git clone https://github.com/linux-rdma/perftest.git /tmp/perftest

echo "Building perftest with CUDA support..."
cd /tmp/perftest
./autogen.sh
./configure --enable-cuda --with-cuda=/usr/local/cuda
make -j$(nproc)
make install

echo "Cleaning up..."
cd /
rm -rf /tmp/perftest
apt-get purge -y git build-essential autoconf automake libtool libibverbs-dev librdmacm-dev pkg-config
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*

echo "perftest with CUDA support installed successfully!"

