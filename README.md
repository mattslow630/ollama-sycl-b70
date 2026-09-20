# ollama-sycl-b70

**Ollama with an Intel Arc SYCL/oneAPI backend, built from Ollama's own source.**

Stock `ollama/ollama` uses a **Vulkan** backend for Intel GPUs. This image adds a
proper **SYCL/oneAPI** backend instead, which on Battlemage (Arc Pro B70 / B580 /
B50) is roughly **2x faster** and offloads **all** model layers to the GPU. You
keep everything else: the standard Ollama API, the `ollama` CLI, and Ollama's
native dynamic model load/unload.

Built on top of the recipe from
[eleiton/ollama-intel-arc](https://github.com/eleiton/ollama-intel-arc), hardened
with the fixes learned on a real Intel Arc Pro B70 (BMG-G31) in an Unraid 7.3
server (Sept 2026).

> **Why not stock Ollama + Vulkan?**
> Measured on the same B70, same qwen3.8:27b model:

| | SYCL (this image) | Stock Ollama + Vulkan |
|---|---|---|
| decode (non-thinking) | **52 tok/s** | 26 tok/s |
| decode (thinking) | **37 tok/s** | 16 tok/s |
| layers on GPU | **66/66** | partial (CPU spill) |

> **What about IPEX-LLM?** Intel's IPEX-LLM project (the old "Ollama portable zip")
> is **archived** (Jan 2026) and flagged with known security issues. This image
> does not use it — the SYCL backend is compiled from Ollama's own source tree
> against Ollama's pinned llama.cpp, so it tracks whatever Ollama version you
> pin.

## Requirements

- Linux with the **`xe`** kernel driver (kernel ≥ 6.8; Unraid 7.2+, Ubuntu 24.04
  HWE, Fedora 40+) — the B70 needs a recent kernel to be probed at all
- `/dev/dri` visible on the host (it is, by default, with `xe` loaded)
- Docker ≥ 24 (any recent build works; Unraid 7.x fine)
- A Battlemage Arc card: **Pro B70 (32 GB)**, B580 (12/24 GB), B50 (16 GB),
  A-series Arc also works (A770/A380)
- ~20 GB free disk for the Docker build (the oneAPI base image + compile stage)
- ~30–60 min build time

## Quick start

```bash
git clone https://github.com/<you>/ollama-sycl-b70
cd ollama-sycl-b70
./scripts/build.sh
```

Then run (single GPU):

```bash
docker run -d --name ollama --restart unless-stopped \
  --device /dev/dri --ipc=host \
  -e ONEAPI_DEVICE_SELECTOR=level_zero:0 \
  -e ZES_ENABLE_SYSMAN=1 \
  -e SYCL_CACHE_PERSISTENT=0 \
  -e OLLAMA_ORIGINS="*" \
  -e OLLAMA_KEEP_ALIVE=10m \
  -p 11434:11434 \
  -v $(pwd)/models:/root/.ollama \
  ollama-sycl:local
```

Verify the GPU is detected (should say `library=SYCL`, your card's name, full VRAM):

```bash
docker logs ollama 2>&1 | grep "inference compute"
```

Pull and run a model:

```bash
docker exec -it ollama ollama pull qwen3:8b
docker exec -it ollama ollama run qwen3:8b "Hello!" --verbose
```

`--verbose` prints `eval rate` — that's your real tokens/s.

### Unraid

Option A — `docker-compose.yml` from this repo (Unraid 7 supports compose):
copy the folder to `/mnt/user/appdata/ollama-sycl-b70`, set `models_dir` in
`.env`, then `docker compose up -d`.

Option B — the included `unraid-template.xml`: drop it into
`/mnt/user/appdata/templates/`, refresh the Docker tab, add the container.

## Update Ollama (keep SYCL)

Ollama ships new versions regularly (new model archs land fast). To bump:

```bash
./scripts/bump-ollama.sh          # checks latest Ollama tag, updates Dockerfile, rebuilds
```

Or manually: change `ARG OLLAMA_VERSION=` at the top of the Dockerfile and
re-run `./scripts/build.sh`. Stage 1 (the SYCL compile) is cached unless the
Ollama pin changes, so routine rebuilds are quick.

If a new Ollama version fails the SYCL compile, that means Ollama bumped its
pinned llama.cpp to a commit with SYCL build breakage — check
`ollama/ollama` `llama/server/CMakeLists.txt` for the pinned commit and file/patch upstream.

## Flaky network? Use the offline build path

GitHub release downloads (Intel `.deb`s, Ollama tarball) are intermittently
flaky over IPv6. Two built-in mitigations:

1. All `wget` calls already use `-4` (force IPv4) with retries.
2. If it still fails: pre-fetch everything, then build offline:

```bash
./scripts/fetch-offline.sh          # downloads debs/ + cache/ with retries
docker build -f Dockerfile.offline -t ollama-sycl:local .
```

## Environment variables

| Var | Default | Notes |
|---|---|---|
| `ONEAPI_DEVICE_SELECTOR` | `level_zero:0` | Pin the dGPU. **If you also have an Intel iGPU**, check `level_zero:1` is the Arc card — run `clinfo` or check `docker logs` for the device name. |
| `ZES_ENABLE_SYSMAN` | `1` | VRAM accounting — keep on |
| `SYCL_CACHE_PERSISTENT` | `0` | **Do not set to 1 on Battlemage** — first-JIT segfaults. Persist the JIT cache instead by mounting a volume at `/root/.cache` (compose does this). |
| `OLLAMA_KEEP_ALIVE` | `10m` | Idle unload time. `-1` = never unload |
| `OLLAMA_ORIGINS` | `*` | CORS for web UIs (Open WebUI, etc.) |
| `OLLAMA_NUM_CTX` | `4096` | Bigger context = more VRAM |
| `OLLAMA_MAX_LOADED_MODELS` | `0` | Leave 0 for full dynamic load/unload |

## Multi-GPU (2x B70)

Pass both render nodes and let Ollama split:

```bash
docker run ... --device /dev/dri ... \
  -e ONEAPI_DEVICE_SELECTOR="level_zero:0;level_zero:1" \
  -e OLLAMA_SPLIT_MODE=tensor -e OLLAMA_SCHED_SPREAD=1 ...
```

## Troubleshooting

- **`inference compute ... library=cpu`** — GPU not visible. Check
  `/dev/dri` is passed, `xe` driver loaded on host (`lsmod | grep xe`), kernel
  ≥ 6.8. On Unraid the B70 needs the card *not* assigned to VMs.
- **`No device` / `level_zero:0` empty** — wrong device index (iGPU present).
  Enumerate: `docker run --rm --device /dev/dri -it <image> clinfo | grep "Device Name"`.
- **Model stuck loading / slow first run** — first SYCL JIT compile. ~30–60 s
  per model size; cached in `/root/.cache` afterwards (mount a volume).
- **`failed to solve: no space left on device`** — the build needs ~20 GB of
  free Docker storage. On Unraid that's the `docker.img` loop (Settings →
  Docker → Storage).
- **B70 firmware** — make sure GSC firmware is current (see
  [this guide](https://gist.github.com/mploschiavo/9968c883c4a872a74e0f38edd7cda2ef));
  a stale GSC firmware can wedge `igsc` and GPU tools.
- **PCIe "Gen1 x1" in lspci** — known Arc reporting artifact, not a defect
  (Intel KB 000094587). Read the link off the bridge node or run a bandwidth
  test, not the endpoint.

## License

MIT — see [LICENSE](LICENSE). Based on the recipe in
[eleiton/ollama-intel-arc](https://github.com/eleiton/ollama-intel-arc) (MIT).
