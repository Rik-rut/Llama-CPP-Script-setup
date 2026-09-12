#!/usr/bin/env bash
# Portable bootstrap for llama.cpp server (Linux/macOS, Git Bash). Idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORT=18123; HOST=127.0.0.1; ENGINE_VERSION=b10740
ENGINE_DIR="engine/llama.cpp-b10740"; MODEL_DIR="models"
[[ -f "$DIR/.env" ]] && { set -a; source "$DIR/.env"; set +a; }

echo "=== llama.cpp setup [$ENGINE_VERSION port=$PORT host=$HOST] ==="
mkdir -p "$DIR/$MODEL_DIR" "$DIR/engine" "$DIR/config" "$DIR/logs"

# migrate legacy flat layout
shopt -s nullglob
for f in "$DIR"/*.gguf; do echo "Moving $(basename "$f") -> $MODEL_DIR/"; mv "$f" "$DIR/$MODEL_DIR/"; done
[[ -f "$DIR/models.conf" && ! -f "$DIR/config/models.conf" ]] && { cp "$DIR/models.conf" "$DIR/config/models.conf"; echo "Copied models.conf -> config/models.conf"; }
[[ ! -f "$DIR/.env" && -f "$DIR/.env.example" ]] && { cp "$DIR/.env.example" "$DIR/.env"; echo "Created .env"; }

command -v curl >/dev/null || { echo "ERROR: curl required"; exit 1; }
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv || echo "WARNING: no NVIDIA GPU detected (CPU fallback)."

ENG="$DIR/$ENGINE_DIR"
if [[ -f "$ENG/llama-server" || -f "$ENG/llama-server.exe" ]]; then
  echo "Engine OK: $ENG"
else
  echo "Downloading llama.cpp $ENGINE_VERSION..."
  OS="$(uname -s)"; ARCH="$(uname -m)"
  case "$OS" in
    Linux)  ZIP="llama-${ENGINE_VERSION}-bin-ubuntu-x64.zip" ;;
    Darwin) ZIP="llama-${ENGINE_VERSION}-bin-macos-arm64.zip" ;;
    MINGW*|MSYS*|CYGWIN*) ZIP="llama-${ENGINE_VERSION}-bin-win-cuda-12.4-x64.zip" ;;
    *) echo "Unsupported OS: $OS. Download manually into $ENG"; exit 1 ;;
  esac
  URL="https://github.com/ggerganov/llama.cpp/releases/download/${ENGINE_VERSION}/${ZIP}"
  mkdir -p "$ENG"
  curl -fL "$URL" -o "$DIR/engine/llama.zip" || { echo "ERROR: download failed: $URL"; exit 1; }
  unzip -o "$DIR/engine/llama.zip" -d "$ENG"
  rm "$DIR/engine/llama.zip"
fi
chmod +x "$ENG"/llama-server 2>/dev/null || true
"$ENG"/llama-server --version 2>/dev/null || "$ENG"/llama-server.exe --version 2>/dev/null || true

if [[ "$HOST" == "0.0.0.0" ]]; then
  echo "HOST=0.0.0.0: open TCP $PORT in your firewall (ufw: sudo ufw allow ${PORT}/tcp)."
else
  echo "HOST=$HOST (localhost-only) -- no inbound firewall needed. Tunnel uses outbound."
fi

OCFG="$HOME/.config/opencode/opencode.json"
if [[ -f "$OCFG" ]]; then
  cp "$OCFG" "$OCFG.bak-$(date +%Y%m%d)"
  sed -i "s/127\.0\.0\.1:8080/127.0.0.1:${PORT}/g" "$OCFG"
  echo "opencode.json patched to 127.0.0.1:$PORT (backup .bak-*)"
else
  echo "No opencode.json -- set llamacpp baseURL to http://127.0.0.1:$PORT/v1 manually."
fi

echo; echo "Models in $MODEL_DIR:"; ls -1 "$DIR/$MODEL_DIR"/*.gguf 2>/dev/null || true
cat <<EOF

DONE. Next:
  1. ./start-server.sh [model.gguf] [port] [host]
  2. Local API: http://127.0.0.1:$PORT/v1
  3. Tunnel: cloudflared tunnel --url http://127.0.0.1:$PORT
EOF
