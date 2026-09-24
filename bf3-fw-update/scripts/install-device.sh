#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
printf 'WARNING: install-device.sh is deprecated; use update-firmware.sh\n' >&2
exec "$SCRIPT_DIR/update-firmware.sh" "$@"
