# STATE.md — llama.cpp (FINAL)

Last updated: 2026-09-12 (reorg: models/ + engine/ layout, fixed port 18123, tunnel-ready localhost bind)

## Current setup (in use)
- **Engine:** llama.cpp b10740 (CUDA 12.4) at `D:\LLM Models\unsloth\engine\llama.cpp-b10740\`
- **Models:** `D:\LLM Models\unsloth\models\` (14x .gguf, config in `config\models.conf`, env in `.env`)
- **Hardware:**
  - GPU: NVIDIA RTX 3050 6GB (5.5 GB usable VRAM, GDDR6 @ 168 GB/s)
  - CPU: Intel Core i5-12400 (6 P-cores / 12 threads, AVX2)
  - RAM: 32 GB DDR4-3200 Dual-Channel (~40-45 GB/s effective bandwidth)
- **Launchers:**
  - `start-server.cmd` / `start-server.sh` — Interactive / argument server with per-model configs (`-t 8 -tb 12`, `http://127.0.0.1:18123` by default; `PORT`/`HOST` from `.env`, auto-bump if busy, writes `.port`)
  - `setup.bat` / `setup.sh` — Portable bootstrap: mkdirs, migrate flat `*.gguf` -> `models/`, download pinned engine, patch opencode provider, print tunnel command. Safe to re-run.
  - `qwen3.6-35b.cmd` — REMOVED (was referenced but missing; use `start-server.cmd Qwen_Qwen3.6-35B-A3B-IQ2_M.gguf`)
  - Defaults & overrides controlled in `config\models.conf` (legacy `models.conf` in root kept for rollback)
- **Agent integration:** opencode provider `llamacpp` + Pi provider `llamacpp` →
  `http://127.0.0.1:18123/v1`, model `qwen3.6-35b-a3b` / `Local Model`, apiKey `sk-llama`.
- Cloudflare Tunnel (same-PC `cloudflared` -> `http://127.0.0.1:18123`, outbound-only, no inbound firewall needed). Localhost bind enabled (`--host 127.0.0.1` via `HOST` in `.env`); set `HOST=0.0.0.0` + `setup.bat` firewall rule `llama-server 18123` only if LAN access needed. Old `llama-server 8080` rule retired. Set `LLAMA_API_KEY` in `.env` if exposing via public tunnel.

---

## Performance Breakthroughs & Locked-In Benchmark Results

| Model | Baseline Setting & Speed | Locked-In Setting | Peak Benchmark Speed | Real Prompt Speed (CLI) | Speedup |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **GLM-4.7-Flash-REAP-23B-A3B-UD-IQ2_M** (7.96 GiB) | `ngl=25, t=6, kv=q4_0` (17.06 t/s) | `ngl=31, t=8, kv=q4_0` | **25.14 t/s** (pp: 59.0 t/s) | **18.6 t/s** (4K ctx) | **+47%** |
| **Qwen3.6-27B-A3B-Coder-IQ2_M** (8.43 GiB) | `ngl=20, t=6, kv=q8_0` (18.49 t/s) | `ngl=27, t=8, kv=q4_0` | **26.51 t/s** (pp: 59.3 t/s) | **21.8 t/s** (4K ctx) | **+43%** |
| **Qwen_Qwen3.6-35B-A3B-IQ2_M** (12.06 GiB) | `ngl=17, t=6, kv=q8_0` (14.59 t/s) | `ngl=19, t=8, kv=q8_0` | **19.72 t/s** (pp: 43.1 t/s) | **16.5 t/s** (4K ctx) | **+35%** |
| **Ling-3.0-tiny-Q4_K_M** (4.49 GiB, 7.9B/1.3B MoE) | (unconfigured) | `ngl=99, t=8, kv=q8_0` | **87.84 t/s** (pp: 287.8 t/s) | **96.2 t/s** (4K ctx) | **5.5x** |
| **Polaris-V1.i1-Q4_K_M** (2.51 GiB, 4.2B dense) | (unconfigured) | `ngl=99, t=8, kv=q8_0` | **43.61 t/s** (pp: 155.4 t/s) | **43.6 t/s** | **2.6x** |

---

## Physical Constraints & The 30-40 t/s Boundary

### 1. The DDR4 Memory Wall on Partial Offloading (23B – 35B models)
- Models > 5.5 GB cannot fit entirely in the RTX 3050's 6GB VRAM.
- In llama.cpp, layers not on the GPU (`N - ngl`) run on CPU using system RAM.
- Even though these are MoE models with ~3B active parameters, evaluating 10–25 layers on the CPU requires continuous streaming of weights over dual-channel DDR4-3200 (~40 GB/s real throughput).
- **Physical ceiling:** On an i5-12400 with DDR4-3200, the maximum possible CPU execution speed for remaining layers of 23B-35B models is **~25 to 26.5 t/s**.
- Exceeding the exact VRAM threshold by even 1 layer causes Windows WDDM to evict buffers over PCIe into shared system memory, collapsing generation speed to 8-10 t/s.
  - GLM-4.7 cliff: `ngl 31-32` is optimal (24-25 t/s); `ngl 33` drops to 16.5 t/s; `ngl 35` drops to 10.6 t/s.
  - Qwen 27B cliff: `ngl 27-28` is optimal (25-26.5 t/s); `ngl 29` drops to 10.0 t/s.
  - Qwen 35B cliff: `ngl 19-20` is optimal (19.7 t/s); `ngl 21` drops to 9.2 t/s.

### 2. Hitting 30 – 40+ t/s (100% GPU VRAM Fit)
- When a model is `<= 5.0 GB`, 100% of layers fit in VRAM (`ngl 99`).
- Computation runs entirely on the RTX 3050 Ampere tensor cores over 168 GB/s GDDR6 with zero CPU layer latency.
- Benchmark proof:
  - **Ling-3.0-tiny-Q4_K_M (4.49 GB):** Runs at **87.8 - 96.2 t/s**!
  - **Polaris-V1 (2.51 GB):** Runs at **43.6 t/s**!
  - For coding tasks where 30-40+ t/s is required, models in the 7B-14B range with <= 5.0 GB footprint (e.g. Qwen2.5-Coder-7B at Q4_K_M or 14B at IQ2_XXS) provide 35-60 t/s.

### 3. Speculative Decoding Findings
- **DFlash (0.4B draft model):** Net loss (14.3 t/s vs 15.3 t/s baseline). CPU drafter steals memory bandwidth from the CPU-offloaded main model.
- **N-Gram Speculative Decoding (`--spec-type ngram-simple`):** Tested on Qwen 27B on code prompt. Dropped speed to 8.3 t/s because batch candidate verification overloads the CPU memory bus during non-repeating reasoning steps.
- **Verdict:** Speculative decoding is strictly counterproductive when the main model is partially offloaded to CPU. It only pays off when the main model runs 100% on GPU with idle compute headroom.

### 4. Threading Optimization
- Default llama.cpp uses `-t 6` (matching 6 physical P-cores).
- Empirical testing showed `-t 8` improves generation and prompt processing by **+7% to +10%** across all models without cache thrashing, as hyperthreaded threads help hide DDR4 memory latency on AVX2 kernels. Launchers now use `-t 8`.

---

## Locked-in Files & Configs
- `config\models.conf` (root `models.conf` kept as rollback copy):
  - `GLM-4.7-Flash-REAP-23B-A3B-UD-IQ2_M.gguf|65536|31|q4_0`
  - `Qwen3.6-27B-A3B-Coder-IQ2_M.gguf|65536|27|q4_0`
  - `Qwen_Qwen3.6-35B-A3B-IQ2_M.gguf|65536|19|q8_0`
  - `Ornith-1.5-35B-A3B-IQ2_M.gguf|65536|19|q8_0`
  - Small models (Ling-3.0, Polaris, Qwen 0.8B, LFM 2.6B, Qwen 2B): `ngl 99`, `kv=q8_0`
- `start-server.cmd`: Updated with `-t 8` flag
- `qwen3.6-35b.cmd`: Updated with `-t 8` flag