#!/bin/bash
# One-shot USB serial module build for OctoPrint.
set -euo pipefail

cd "$(dirname "$0")/.."

# ponytail: VM provisioning can miss deps after script changes; install only if needed.
if ! command -v flex >/dev/null || ! command -v bison >/dev/null; then
    sudo bash scripts/build-deps.sh
fi

bash scripts/setup-kernel-build.sh
# ponytail: modules_prepare lacks vmlinux/Module.symvers; build script allows modpost warnings.
bash scripts/build-usb-modules.sh
