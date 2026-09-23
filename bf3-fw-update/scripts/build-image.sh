#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
image=${1:?Usage: build-image.sh REGISTRY/IMAGE:TAG}
engine=${CONTAINER_ENGINE:-}

if [[ -z $engine ]]; then
    if command -v docker >/dev/null 2>&1; then
        engine=docker
    elif command -v podman >/dev/null 2>&1; then
        engine=podman
    else
        echo "ERROR: docker or podman is required" >&2
        exit 1
    fi
fi
command -v "$engine" >/dev/null 2>&1 || {
    echo "ERROR: requested container engine not found: $engine" >&2
    exit 1
}

"$engine" build --platform linux/amd64 -f "$PROJECT_DIR/Containerfile" \
    -t "$image" "$PROJECT_DIR"

echo "Built $image"
echo "Push with: $engine push $image"
echo "Then use its immutable registry digest with deploy_pod_to_node.sh."
