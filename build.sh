#!/bin/bash

set -e

local_image_name="localhost/networking-debug-container"

# Check if buildx is available
if docker buildx version &> /dev/null; then
    echo "Using docker buildx to build for linux/amd64..."
    docker buildx build --platform linux/amd64 --load -t $local_image_name .
else
    echo "Using docker build (buildx not available)..."
    docker build -t $local_image_name .
fi

echo "Build complete: $local_image_name"

# To run the locally built image:
# docker run -it --rm --gpus=all --network=host --privileged --device=/dev/infiniband/ localhost/networking-debug-container
