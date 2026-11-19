#!/usr/bin/env bash
# Build entry point: run the end-to-end test, then produce dist/.
#
#   ./build.sh
#   SKIP_TESTS=1 ./build.sh       # package only
set -euo pipefail
cd "$(dirname "$0")"

if [ "${SKIP_TESTS:-0}" != 1 ]; then
    ./scripts/test-server.sh
fi
./scripts/build-dist.sh
