#!/usr/bin/env bash
# Pre-fetch all external assets so Dockerfile.offline can build without network.
# Handles the flaky GitHub/IPv6 problem with retries + forced IPv4.
set -euo pipefail
cd "$(dirname "$0")/.."

CR=$(grep -m1 '^ARG COMPUTE_RUNTIME_VERSION=' Dockerfile | cut -d= -f2)
LZ=$(grep -m1 '^ARG LEVEL_ZERO_VERSION=' Dockerfile | cut -d= -f2)
IGC=$(grep -m1 '^ARG IGC_VERSION=' Dockerfile | cut -d= -f2)
IGCB=$(grep -m1 '^ARG IGC_BUILD=' Dockerfile | cut -d= -f2)
GMM=$(grep -m1 '^ARG GMM_VERSION=' Dockerfile | cut -d= -f2)
OV=$(grep -m1 '^ARG OLLAMA_VERSION=' Dockerfile | cut -d= -f2)

mkdir -p debs cache

fetch() {
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then echo "  skip $dest (exists)"; return; fi
  echo "  get $dest"
  wget -4 --tries=8 --waitretry=5 -O "$dest.part" "$url" && mv "$dest.part" "$dest"
}

echo "==> Intel GPU .debs -> debs/"
fetch "https://github.com/oneapi-src/level-zero/releases/download/v${LZ}/libze1_${LZ}+u24.04_amd64.deb" \
      "debs/libze1_${LZ}+u24.04_amd64.deb"
fetch "https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC}/intel-igc-core-2_${IGC}+${IGCB}_amd64.deb" \
      "debs/intel-igc-core-2_${IGC}+${IGCB}_amd64.deb"
fetch "https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC}/intel-igc-opencl-2_${IGC}+${IGCB}_amd64.deb" \
      "debs/intel-igc-opencl-2_${IGC}+${IGCB}_amd64.deb"
fetch "https://github.com/intel/compute-runtime/releases/download/${CR}/intel-ocloc_${CR}-0_amd64.deb" \
      "debs/intel-ocloc_${CR}-0_amd64.deb"
fetch "https://github.com/intel/compute-runtime/releases/download/${CR}/intel-opencl-icd_${CR}-0_amd64.deb" \
      "debs/intel-opencl-icd_${CR}-0_amd64.deb"
fetch "https://github.com/intel/compute-runtime/releases/download/${CR}/libigdgmm12_${GMM}_amd64.deb" \
      "debs/libigdgmm12_${GMM}_amd64.deb"
fetch "https://github.com/intel/compute-runtime/releases/download/${CR}/libze-intel-gpu1_${CR}-0_amd64.deb" \
      "debs/libze-intel-gpu1_${CR}-0_amd64.deb"

echo "==> Ollama tarball -> cache/"
fetch "https://github.com/ollama/ollama/releases/download/v${OV}/ollama-linux-amd64.tar.zst" \
      "cache/ollama-linux-amd64.tar.zst"
zstd -t cache/ollama-linux-amd64.tar.zst && echo "  tarball verified OK"

echo "==> All assets present. Build with:"
echo "    docker build -f Dockerfile.offline -t ollama-sycl:local ."
