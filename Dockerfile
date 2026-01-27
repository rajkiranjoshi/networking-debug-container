# ============================================================================
# Stage 1: Builder stage with full CUDA/ROCm toolkits and build dependencies
# ============================================================================
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        gnupg2 \
        ca-certificates \
        apt-transport-https && \
    rm -rf /var/lib/apt/lists/*

# Install CUDA Toolkit (needed for building with CUDA support)
RUN wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    rm cuda-keyring_1.1-1_all.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        cuda-toolkit-12-8 && \
    rm -rf /var/lib/apt/lists/*

ENV PATH=/usr/local/cuda-12.8/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:${LD_LIBRARY_PATH}

# Install ROCm Toolkit (needed for building with ROCm/AMD GPU support)
RUN wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor -o /usr/share/keyrings/rocm-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm-archive-keyring.gpg] https://repo.radeon.com/rocm/apt/6.3 noble main" > /etc/apt/sources.list.d/rocm.list && \
    echo 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600' > /etc/apt/preferences.d/rocm-pin-600 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        rocm-dev && \
    rm -rf /var/lib/apt/lists/*

ENV PATH=/opt/rocm/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/rocm/lib:${LD_LIBRARY_PATH}

# Install Mellanox OFED (including development libraries needed for building)
RUN wget -qO - https://www.mellanox.com/downloads/ofed/RPM-GPG-KEY-Mellanox | gpg --dearmor -o /usr/share/keyrings/mellanox-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/mellanox-archive-keyring.gpg] https://linux.mellanox.com/public/repo/mlnx_ofed/latest/ubuntu24.04/x86_64 ./" > /etc/apt/sources.list.d/mlnx_ofed.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        libibverbs-dev \
        librdmacm-dev \
        libibumad-dev \
        libpci-dev \
        ibverbs-utils \
        perftest && \
    rm -rf /var/lib/apt/lists/*

# Install build dependencies for perftest
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        build-essential \
        autoconf \
        automake \
        libtool \
        pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Build perftest with both CUDA and ROCm support
RUN git clone https://github.com/linux-rdma/perftest.git /tmp/perftest && \
    cd /tmp/perftest && \
    git checkout tags/25.10.0-0.128 && \
    ./autogen.sh && \
    export CUDA_H_PATH=/usr/local/cuda/include/cuda.h && \
    ./configure --prefix=/usr/local/perftest-gpu \
        --enable-cuda --with-cuda=/usr/local/cuda \
        --enable-rocm --with-rocm=/opt/rocm && \
    make -j$(nproc) && \
    make install && \
    echo "Perftest binaries built with CUDA and ROCm support"

# ============================================================================
# Stage 2: Final runtime image with only necessary components
# ============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        gnupg2 \
        ca-certificates \
        apt-transport-https && \
    rm -rf /var/lib/apt/lists/*

# Install ONLY CUDA runtime libraries (not the full toolkit)
# Note: cuda packages automatically set up /usr/local/cuda symlink via update-alternatives
RUN wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    rm cuda-keyring_1.1-1_all.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        cuda-cudart-12-8 \
        cuda-nvrtc-12-8 && \
    rm -rf /var/lib/apt/lists/* && \
    # Create unversioned symlink for libcudart.so (runtime package only has versioned libs)
    ln -sf /usr/local/cuda/lib64/libcudart.so.12 /usr/local/cuda/lib64/libcudart.so

# Install ROCm runtime libraries (hip-runtime-amd includes necessary AMD GPU runtime)
# Install amd-smi for AMD GPU monitoring (modern replacement for rocm-smi)
# Note: amd-smi-lib provides the library, we also need python3 and dependencies for the CLI wrapper
RUN wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor -o /usr/share/keyrings/rocm-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm-archive-keyring.gpg] https://repo.radeon.com/rocm/apt/6.3 noble main" > /etc/apt/sources.list.d/rocm.list && \
    echo 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600' > /etc/apt/preferences.d/rocm-pin-600 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        hip-runtime-amd \
        rocm-core \
        amd-smi-lib \
        python3 \
        python3-pip \
        python3-yaml && \
    pip3 install --break-system-packages amdsmi && \
    rm -rf /var/lib/apt/lists/*

ENV PATH=/usr/local/cuda-12.8/bin:/opt/rocm/bin:/usr/sbin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:/opt/rocm/lib:${LD_LIBRARY_PATH}

# Install Mellanox OFED - ONLY runtime packages and essential tools
# Instead of mlnx-ofed-all, we install specific packages we need
RUN wget -qO - https://www.mellanox.com/downloads/ofed/RPM-GPG-KEY-Mellanox | gpg --dearmor -o /usr/share/keyrings/mellanox-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/mellanox-archive-keyring.gpg] https://linux.mellanox.com/public/repo/mlnx_ofed/latest/ubuntu24.04/x86_64 ./" > /etc/apt/sources.list.d/mlnx_ofed.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        libibverbs1 \
        librdmacm1 \
        libibumad3 \
        libibmad5 \
        libpci3 \
        ibverbs-utils \
        ibverbs-providers \
        rdma-core \
        mlnx-tools \
        mlnx-ofed-kernel-utils \
        mft \
        mstflint \
        infiniband-diags && \
    rm -rf /var/lib/apt/lists/*

# Copy system packages list and install utilities
COPY system-packages.txt /tmp/system-packages.txt
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /tmp/system-packages.txt) && \
    rm -rf /var/lib/apt/lists/* /tmp/system-packages.txt

# Copy CUDA+ROCm-compiled perftest binaries from builder stage
COPY --from=builder /usr/local/perftest-gpu/bin/* /usr/local/bin/

# Verify perftest binaries work
RUN echo "Verifying perftest binaries..." && \
    ls -lh /usr/local/bin/ib_* && \
    ldd /usr/local/bin/ib_write_bw || true

# Update PCI IDs database
RUN update-pciids

# Enable colored prompt in bash
RUN sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/' /root/.bashrc

# Copy scripts directory to /root
COPY scripts /root/scripts

# Set working directory to /root
WORKDIR /root

# Default command
CMD ["/bin/bash"]



