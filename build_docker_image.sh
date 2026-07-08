#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

VARIANT="${1:-default}"
IMAGE_BASE="networking-debug"

case "$VARIANT" in
    default)
        DOCKERFILE="Dockerfile"
        IMAGE_TAG="${IMAGE_BASE}:latest"
        DESC="IB/RoCE (Mellanox OFED + CUDA + ROCm)"
        ;;
    efa)
        DOCKERFILE="Dockerfile.efa"
        IMAGE_TAG="${IMAGE_BASE}:efa"
        DESC="AWS EFA (EFA installer + CUDA)"
        ;;
    *)
        echo -e "${RED}Unknown variant: $VARIANT${NC}"
        echo ""
        echo "Usage: $0 [default|efa]"
        echo ""
        echo "  default  IB/RoCE image with Mellanox OFED, CUDA, ROCm"
        echo "  efa      AWS EFA image with EFA installer, CUDA"
        exit 1
        ;;
esac

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Building Docker Image${NC}"
echo -e "${BLUE}============================================${NC}"
echo "Variant:    $DESC"
echo "Dockerfile: $DOCKERFILE"
echo "Image tag:  $IMAGE_TAG"
echo ""

if docker buildx version &> /dev/null; then
    echo "Using docker buildx to build for linux/amd64..."
    docker buildx build --platform linux/amd64 --load -f "$DOCKERFILE" -t "$IMAGE_TAG" .
else
    echo "Using docker build..."
    docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" .
fi

echo ""
echo -e "${GREEN}✓ Build complete: $IMAGE_TAG${NC}"

SIZE=$(docker image inspect "$IMAGE_TAG" --format='{{.Size}}' | awk '{printf "%.2f", $1/1024/1024/1024}')
echo -e "Image size: ${GREEN}${SIZE} GB${NC}"

echo ""
echo "Next steps:"
echo "  1. Test interactively: docker run --rm -it --gpus=all --network=host $IMAGE_TAG"
