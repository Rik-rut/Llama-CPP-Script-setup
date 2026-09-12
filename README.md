# Llama CPP Script Setup

Portable launcher + bootstrap for [llama.cpp](https://github.com/ggerganov/llama.cpp) `llama-server` with per-model tuning, a fixed uncommon port, and Kaggle support.

## Layout

```
setup.bat / setup.sh          portable bootstrap (safe to re-run)
start-server.cmd / .sh        interactive or argument launcher
.env.example -> .env          PORT, HOST, engine version, optional API key
config/models.conf            per-model ctx | ngl | kv-cache tuning
config/models.conf.kaggle-t4  retuned variant for Tesla T4 16GB
kaggle-quickstart.ipynb       GPU notebook: setup -> fetch model -> serve -> test
models/ engine/ logs/         machine-local content (gitignored, .gitkeep tracked)
```

## Quickstart

**Windows:** `setup.bat`, then `start-server.cmd [model.gguf] [port] [host]`
**Linux/macOS:** `./setup.sh`, then `./start-server.sh [model.gguf] [port] [host]`
**Kaggle:** upload/run `kaggle-quickstart.ipynb` (needs GPU + Internet enabled).

Local OpenAI-compatible endpoint: `http://127.0.0.1:18123/v1`

## Config

- **Port** defaults to `18123` (avoids `8080` conflicts). If busy, the launcher auto-bumps and writes the actual port to `.port`. Override via CLI arg, `PORT_OVERRIDE`, or `.env`.
- **Host** defaults to `127.0.0.1` (localhost-only — correct for Cloudflare Tunnel, which is outbound-only). Set `HOST=0.0.0.0` only for LAN access; `setup.bat` then adds the firewall rule.
- **Per-model tuning** lives in `config/models.conf` (`filename|ctx|ngl|kv`). `ngl` values are tuned for RTX 3050 6GB VRAM cliffs — on other GPUs start from `models.conf.kaggle-t4`. Unlisted models get smart defaults (`ngl=99` under 5.7GB).
- **API key:** leave `LLAMA_API_KEY` empty for local use (any client key is accepted). Set a real value before exposing via a public tunnel, and mirror it in the client config.
- **Tunnel:** `cloudflared tunnel --url http://127.0.0.1:18123`
