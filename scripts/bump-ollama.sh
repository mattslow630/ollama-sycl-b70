#!/usr/bin/env bash
# Check the latest Ollama release, bump the Dockerfile pin, rebuild.
# Usage: ./scripts/bump-ollama.sh
set -euo pipefail
cd "$(dirname "$0")/.."

LATEST=$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4 | tr -d 'v')
CURRENT=$(grep -m1 '^ARG OLLAMA_VERSION=' Dockerfile | cut -d= -f2)

echo "Current: $CURRENT   Latest: $LATEST"
if [ "$LATEST" = "$CURRENT" ]; then
  echo "Already on latest. Nothing to do."
  exit 0
fi

sed -i "s/^ARG OLLAMA_VERSION=.*/ARG OLLAMA_VERSION=$LATEST/" Dockerfile
echo "==> Bumped Dockerfile to Ollama $LATEST, rebuilding..."
./scripts/build.sh "$LATEST"

echo "==> Verify SYCL still loads (new Ollama may pin a new llama.cpp):"
echo "    docker run --rm --device /dev/dri -it ollama-sycl:local ollama run qwen3:8b 'hi' --verbose"
