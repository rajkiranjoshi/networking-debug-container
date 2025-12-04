#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

IMAGE_TAG="networking-debug:latest"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Building Docker Image${NC}"
echo -e "${BLUE}============================================${NC}"
echo "Dockerfile: Dockerfile"
echo "Image tag:  $IMAGE_TAG"
echo ""

# Build the image
if docker buildx version &> /dev/null; then
    echo "Using docker buildx to build for linux/amd64..."
    docker buildx build --platform linux/amd64 --load -t "$IMAGE_TAG" .
else
    echo "Using docker build..."
    docker build -t "$IMAGE_TAG" .
fi

echo ""
echo -e "${GREEN}✓ Build complete: $IMAGE_TAG${NC}"

# Get image size
SIZE=$(docker image inspect "$IMAGE_TAG" --format='{{.Size}}' | awk '{printf "%.2f", $1/1024/1024/1024}')
echo -e "Image size: ${GREEN}${SIZE} GB${NC}"

echo ""
echo "Next steps:"
echo "  1. Verify tools:       ./verify-tools.sh $IMAGE_TAG"
echo "  2. Test interactively: docker run --rm -it --gpus=all --network=host $IMAGE_TAG"
