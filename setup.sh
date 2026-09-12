#!/usr/bin/env bash
# Portable bootstrap for llama.cpp server (Linux/macOS, Git Bash). Idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORT=18123; HOST=127.0.0.1; ENGINE_VERSION=b10740; ENGINE_URL=""
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
  BASE="https://github.com/ggml-org/llama.cpp/releases/download/${ENGINE_VERSION}"
  OS="$(uname -s)"; ARCH="$(uname -m)"
  # NOTE: release assets are .tar.gz on Linux/macOS, .zip on Windows.
  # There is no Linux CUDA build — NVIDIA GPUs use the Vulkan build.
  if [[ -n "${ENGINE_URL:-}" ]]; then
    URLS=("$ENGINE_URL")
  else
    case "$OS" in
      Linux)
        if command -v nvidia-smi >/dev/null 2>&1; then
          URLS=("$BASE/llama-${ENGINE_VERSION}-bin-ubuntu-vulkan-x64.tar.gz"
                "$BASE/llama-${ENGINE_VERSION}-bin-ubuntu-x64.tar.gz")
          echo "NVIDIA GPU detected -> Vulkan build (fallback: CPU build)."
        elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
          URLS=("$BASE/llama-${ENGINE_VERSION}-bin-ubuntu-arm64.tar.gz")
        else
          URLS=("$BASE/llama-${ENGINE_VERSION}-bin-ubuntu-x64.tar.gz")
        fi
        ;;
      Darwin)
        if [[ "$ARCH" == "arm64" ]]; then
          URLS=("$BASE/llama-${ENGINE_VERSION}-bin-macos-arm64.tar.gz")
        else
          URLS=("$BASE/llama-${ENGINE_VERSION}-bin-macos-x64.tar.gz")
        fi
        ;;
      MINGW*|MSYS*|CYGWIN*)
        URLS=("$BASE/llama-${ENGINE_VERSION}-bin-win-cuda-12.4-x64.zip")
        ;;
      *) echo "Unsupported OS: $OS. Set ENGINE_URL in .env or download manually into $ENG"; exit 1 ;;
    esac
  fi
  mkdir -p "$ENG"
  OK=""
  for URL in "${URLS[@]}"; do
    echo "Trying: $URL"
    if curl -fL "$URL" -o "$DIR/engine/llama-pkg"; then OK="$URL"; break; fi
    echo "Not found, trying next..."
  done
  [[ -z "$OK" ]] && { echo "ERROR: all downloads failed. Set ENGINE_URL in .env or download manually into $ENG"; exit 1; }
  if [[ "$OK" == *.zip ]]; then
    unzip -o "$DIR/engine/llama-pkg" -d "$ENG"
  else
    tar xzf "$DIR/engine/llama-pkg" -C "$ENG"
  fi
  rm "$DIR/engine/llama-pkg"
  # Normalize nested archive layout: Linux .tar.gz wraps everything in llama-bXXXX/
  if [[ ! -f "$ENG/llama-server" && ! -f "$ENG/llama-server.exe" ]]; then
    FOUND="$(find "$ENG" -mindepth 2 -maxdepth 3 -type f \( -name llama-server -o -name llama-server.exe \) -print -quit)"
    if [[ -n "$FOUND" ]]; then
      SRC="$(dirname "$FOUND")"
      echo "Flattening nested archive layout: $SRC -> $ENG"
      for f in "$SRC"/* "$SRC"/.[!.]* "$SRC"/..?*; do
        [[ -e "$f" || -L "$f" ]] && mv "$f" "$ENG"/
      done
      rmdir "$SRC" 2>/dev/null || true
    fi
  fi
  [[ -f "$ENG/llama-server" || -f "$ENG/llama-server.exe" ]] || { echo "ERROR: llama-server missing after extract. Check archive layout in $ENG"; exit 1; }
  echo "Engine installed from: $OK"
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
