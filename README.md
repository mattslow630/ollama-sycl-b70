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
git clone https://github.com/mattslow630/ollama-sycl-b70
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
  -e OLLAMA_KV_CACHE_TYPE=q8_0 \
  -e OLLAMA_FLASH_ATTENTION=true \
  -p 11434:11434 \
  -v $(pwd)/models:/root/.ollama \
  ollama-sycl:local
```

> **`--ipc=host` is required, not optional.** The SYCL attention kernels
> coordinate threads through shared memory; without the host IPC namespace the
> default 64 MB `/dev/shm` silently caps decode ~10-15% below its real speed.
> If you recreated a container and it got slower for no reason, check this first.

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
copy the folder to `/mnt/user/appdata/ollama-sycl-b70`, then
`cp .env.example .env` and set `MODELS_DIR` to where you want your models
(e.g. `/mnt/user/appdata/ollama/models`), then `docker compose up -d`.

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
| `ONEAPI_DEVICE_SELECTOR` | `level_zero:0` | Pin the dGPU. **If you also have an Intel iGPU**, check `level_zero:1` is the Arc card — check `docker logs ollama` for the device name on `inference compute`. |
| `ZES_ENABLE_SYSMAN` | `1` | VRAM accounting — keep on |
| `SYCL_CACHE_PERSISTENT` | `0` | **Do not set to 1 on Battlemage** — first-JIT segfaults. Persist the JIT cache instead by mounting a volume at `/root/.cache` (compose does this). |
| `OLLAMA_KEEP_ALIVE` | `10m` | Idle unload time. `-1` = never unload |
| `OLLAMA_KV_CACHE_TYPE` | (unset) | KV cache quant, e.g. `q8_0`. Halves context VRAM, near-lossless. **Requires `OLLAMA_FLASH_ATTENTION=true`** |
| `OLLAMA_FLASH_ATTENTION` | `false` | Set `true` when using a quantized KV cache |
| `OLLAMA_ORIGINS` | `*` | CORS for web UIs (Open WebUI, etc.) |
| `OLLAMA_NUM_CTX` | `4096` | Bigger context = more VRAM |
| `OLLAMA_MAX_LOADED_MODELS` | `0` | Leave 0 for full dynamic load/unload |

## Recommended models & measured performance (Intel Arc Pro B70, 32 GB)

All numbers below measured on this image (Ollama 0.34.2 + SYCL), B70 at stock
settings, `/no_think`, 300-token decode bench with a 1k-token prompt, MTP
speculative decoding active where the model ships a draft head.

### The recipe that runs

For 27B-class **dense** models on 32 GB, the winning configuration is:

```
OLLAMA_KV_CACHE_TYPE=q8_0
OLLAMA_FLASH_ATTENTION=true
```

- **q8_0 KV cache** halves the context buffer vs the f16 default (2.7 GB vs
  5.1 GB at 80k cells for Qwen3.8-27B) for near-lossless quality
  (KL-divergence ~0.003). A/B measured **speed-neutral to +10%**, not slower.
- **Flash attention is mandatory with quantized V cache** — the runner refuses
  to start without it (`quantized V cache requires flash_attn to be enabled`).
- Ollama 0.34's env var takes a **single** type for K and V (`q8_0:q4_1`
  asymmetric form is rejected; per-model `PARAMETER type_k` doesn't exist in
  this build). q8_0 for both is the conservative near-lossless choice.
- This buys ~2.4 GB of VRAM headroom at the 80k ceiling — enough to stop the
  "pinned at 31.8/31.9 GiB" behavior in long agent conversations, where the
  KV/prompt-cache state grows with every message until the LRU evicts it.

### Qwen3.8-27B lineup (dense, MTP draft head included)

| Model tag | Weights | Ctx | KV (q8_0) | Decode (measured) | Notes |
|---|---|---|---|---|---|
| `qwen3.8:27b-80k` | 16.8 GB (Q4) | 80k | 2.7 GB | **~41 tok/s** | Workhorse. 66/66 layers GPU, ~30.5 GiB total loaded |
| `qwen3.8-27b-q5-64k` | 20.2 GB (Q5_K_XL) | 64k | ~2.2 GB | ~31 tok/s | Quality + long ctx |
| `qwen3.8-27b-q6-48k` | 22.0 GB (Q6_K) | 48k | ~1.7 GB | ~31 tok/s | Max weight fidelity |

VRAM math (B70 = 31.9 GiB visible): `weights + KV + ~2 GB SYCL/runtime buffers`.
Q4@80k lands at ~30.5 GiB total — tight but clean, 66/66 layers, zero CPU
spill. Q6@48k leaves ~8 GB free. Past 96k ctx the Q4 KV overflows (measured
cliffs: 96k = 22 tok/s with 768 MB spill, 128k = 12 tok/s with 3 GB on CPU).

### Performance expectations

- **Decode:** 30-45 tok/s for 27B dense with MTP. MTP draft acceptance is
  content-dependent (~45-93%); a "fast day" hits ~56 tok/s on Q4, typical
  agent traffic lands ~37-42. Don't chase the high number — it's not a config
  you can set.
- **Prefill:** ~150-220 tok/s at short prompts via the API path.
- **Small models (context):** 8-14B class runs ~2x faster (e.g. 48+ tok/s
  on 14B) — good for fast auxiliary tasks sharing the card.
- **First response after idle:** expect ~20-30 s cold load (VRAM read + SYCL
  JIT) unless `OLLAMA_KEEP_ALIVE` still holds the model.
- **Reloads between models** are disk-bound on NVMe (~10-15 s); no storage
  trick helps, the weights have to move.

### Dynamic model swapping (why this stack)

`OLLAMA_MAX_LOADED_MODELS=0` (default) + `OLLAMA_KEEP_ALIVE` gives you Ollama's
dynamic load/unload: small auxiliary models (image description, ASR) boot on
demand and Ollama evicts a large resident model to make room, then reloads it
on the next request. Ollama 0.34 also retries with eviction on OOM. This is the
whole point of running inference through Ollama instead of a pinned
llama-server for a 24/7 multi-purpose box.

Unloading manually: `ollama stop <model>` (instant VRAM release).

### Rebuild caveat

Creating a new model tag via `FROM <existing> + PARAMETER num_ctx ...` reuses
the weight blobs (zero download) — use this to make ctx-size variants. Do not
confuse that with re-encoding: the KV cache type is a **runtime** env var,
never a property baked into the GGUF.

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
  Enumerate devices from Ollama's own log: start the container with
  `--device /dev/dri` added and run `docker logs ollama 2>&1 | grep "inference
  compute"` — the device name shown is what bound to `level_zero:0`. If it's
  your iGPU, switch to `level_zero:1`.
- **Model stuck loading / slow first run** — first SYCL JIT compile. ~30–60 s
  per model size; cached in `/root/.cache` afterwards (mount a volume).
- **Decode ~10-15% slower than expected after a container recreate** — you
  dropped `--ipc=host`. SYCL thread synchronization needs the host IPC
  namespace; the default 64 MB `/dev/shm` caps you ~10-15% below real speed.
  Verify:
  `docker inspect ollama --format '{{.HostConfig.IpcMode}}'` → must be `host`.
- **`quantized V cache requires flash_attn to be enabled`** — you set
  `OLLAMA_KV_CACHE_TYPE` without `OLLAMA_FLASH_ATTENTION=true`. Set both, or
  drop the KV quant.
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
