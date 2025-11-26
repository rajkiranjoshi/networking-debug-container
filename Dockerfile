FROM ubuntu:24.04

# Set environment to avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Update package lists and install prerequisites
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        gnupg2 \
        ca-certificates \
        apt-transport-https && \
    rm -rf /var/lib/apt/lists/*

# Install CUDA Toolkit 12.8
RUN wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    rm cuda-keyring_1.1-1_all.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        cuda-toolkit-12-8 && \
    rm -rf /var/lib/apt/lists/*

# Set CUDA environment variables
ENV PATH=/usr/local/cuda-12.8/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:${LD_LIBRARY_PATH}

# Install Mellanox OFED
# Note: Using the repository method for Ubuntu 24.04
RUN wget -qO - https://www.mellanox.com/downloads/ofed/RPM-GPG-KEY-Mellanox | gpg --dearmor -o /usr/share/keyrings/mellanox-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/mellanox-archive-keyring.gpg] https://linux.mellanox.com/public/repo/mlnx_ofed/latest/ubuntu24.04/x86_64 ./" > /etc/apt/sources.list.d/mlnx_ofed.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        mlnx-ofed-all \
        mlnx-tools \
        ibverbs-utils \
        mft && \
    rm -rf /var/lib/apt/lists/*

# Copy system packages list and installation scripts
COPY system-packages.txt /tmp/system-packages.txt
COPY install-perftest-cuda.sh /tmp/install-perftest-cuda.sh

# Install system packages from file (excluding perftest - we'll build it with CUDA)
RUN apt-get update && \
    apt-get install -y --no-install-recommends $(cat /tmp/system-packages.txt) && \
    rm -rf /var/lib/apt/lists/* /tmp/system-packages.txt

# Build and install perftest with CUDA support
RUN chmod +x /tmp/install-perftest-cuda.sh && \
    /tmp/install-perftest-cuda.sh && \
    rm /tmp/install-perftest-cuda.sh

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
