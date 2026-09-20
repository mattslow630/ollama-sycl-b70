#!/usr/bin/env bash
# Build the ollama-sycl image.
# Usage: ./scripts/build.sh [OLLAMA_VERSION]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep -m1 '^ARG OLLAMA_VERSION=' Dockerfile | cut -d= -f2)}"
TAG="ollama-sycl:local"

echo "==> Building $TAG (Ollama $VERSION) — first run takes 30-60 min (oneAPI base + SYCL compile)"
docker build --build-arg OLLAMA_VERSION="$VERSION" -t "$TAG" .

echo "==> Done. Quick check:"
echo "    docker run --rm --device /dev/dri -e ONEAPI_DEVICE_SELECTOR=level_zero:0 -it $TAG /usr/bin/ollama --version"
