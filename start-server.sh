#!/usr/bin/env bash
# llama.cpp server launcher (parity with start-server.cmd)
# Usage: ./start-server.sh [model.gguf] [port] [host]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORT="${PORT_OVERRIDE:-}"
HOST="${HOST_OVERRIDE:-}"
ENGINE_DIR="engine/llama.cpp-b10740"
MODEL_DIR="models"
LLAMA_API_KEY="${LLAMA_API_KEY:-}"

if [[ -f "$DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$DIR/.env"
  set +a
fi
PORT="${1:+}"; # placeholder to keep set -u happy
PORT="${2:-${PORT_OVERRIDE:-${PORT:-18123}}}"
HOST="${3:-${HOST_OVERRIDE:-${HOST:-127.0.0.1}}}"
MODEL_ARG="${1:-}"

if [[ ! -d "$DIR/$MODEL_DIR" ]] || ! ls "$DIR/$MODEL_DIR"/*.gguf >/dev/null 2>&1; then
  MODEL_DIR="." # legacy flat layout fallback
fi
CONF="$DIR/config/models.conf"
[[ -f "$CONF" ]] || CONF="$DIR/models.conf"
ENG="$DIR/$ENGINE_DIR"
[[ -x "$ENG/llama-server" ]] || [[ -f "$ENG/llama-server" ]] || {
  if [[ -f "$DIR/llama.cpp/llama-server" ]]; then ENG="$DIR/llama.cpp"; fi
}
if [[ ! -f "$ENG/llama-server" && ! -f "$ENG/llama-server.exe" ]]; then
  echo "ERROR: llama-server not found in $ENG. Run ./setup.sh first."
  exit 1
fi
BIN="$ENG/llama-server"
[[ -f "$BIN.exe" && ! -f "$BIN" ]] && BIN="$BIN.exe"

CTX=131000; NGL=17; KV=q8_0; DRAFT_FILE=""; SPEC_TYPE="none"; SPEC_N_MAX=3
MODEL_FILE=""

if [[ -n "$MODEL_ARG" ]]; then
  if [[ -f "$DIR/$MODEL_DIR/$MODEL_ARG" ]]; then MODEL_FILE="$MODEL_ARG"
  else echo "Model not found: $MODEL_ARG"; fi
fi

if [[ -z "$MODEL_FILE" ]]; then
  mapfile -t MODELS < <(ls -1 "$DIR/$MODEL_DIR"/*.gguf 2>/dev/null | xargs -n1 basename 2>/dev/null || true)
  if [[ ${#MODELS[@]} -eq 0 ]]; then echo "No .gguf files in $MODEL_DIR/"; exit 1; fi
  echo "Available models (from $MODEL_DIR):"
  for i in "${!MODELS[@]}"; do printf "  %d. %s\n" $((i+1)) "${MODELS[$i]}"; done
  read -rp "Pick model number [1]: " sel
  sel="${sel:-1}"
  MODEL_FILE="${MODELS[$((sel-1))]:-}"
  [[ -z "$MODEL_FILE" ]] && { echo "Invalid choice."; exit 1; }
fi

# smart default: <5.7GB -> full GPU offload
SIZE=$(stat -c%s "$DIR/$MODEL_DIR/$MODEL_FILE" 2>/dev/null || stat -f%z "$DIR/$MODEL_DIR/$MODEL_FILE" 2>/dev/null || echo 0)
if [[ "$SIZE" -lt 5700000000 ]]; then NGL=99; fi

if [[ -f "$CONF" ]]; then
  while IFS='|' read -r f c n k d s m; do
    [[ "$f" =~ ^#.*$ || -z "$f" ]] && continue
    if [[ "$f" == "$MODEL_FILE" ]]; then
      CTX="${c:-$CTX}"; NGL="${n:-$NGL}"; KV="${k:-$KV}"
      DRAFT_FILE="${d:-}"; SPEC_TYPE="${s:-none}"; SPEC_N_MAX="${m:-3}"
    fi
  done < "$CONF"
fi

SPEC_ARGS=()
if [[ -n "$DRAFT_FILE" && -f "$DIR/$MODEL_DIR/$DRAFT_FILE" ]]; then
  SPEC_ARGS=(-md "$DIR/$MODEL_DIR/$DRAFT_FILE" --spec-type "$SPEC_TYPE" --spec-draft-n-max "$SPEC_N_MAX" --fit off -ngld 0)
fi

# find free port (bump if busy)
TRY_PORT="$PORT"; TRIES=0
while (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":$TRY_PORT ") || \
      (command -v lsof >/dev/null && lsof -iTCP:"$TRY_PORT" -sTCP:LISTEN >/dev/null 2>&1) || \
      (command -v netstat >/dev/null && netstat -an 2>/dev/null | grep -q "[.:]$TRY_PORT .*LISTEN"); do
  TRIES=$((TRIES+1)); [[ $TRIES -ge 20 ]] && { echo "ERROR: ports busy. Pass a free port: ./start-server.sh [model] [port]"; exit 1; }
  TRY_PORT=$((TRY_PORT+1))
done
PORT="$TRY_PORT"
echo "$PORT" > "$DIR/.port"

KEY_ARGS=()
[[ -n "${LLAMA_API_KEY:-}" ]] && KEY_ARGS=(--api-key "$LLAMA_API_KEY")

echo "Starting Local Model = $MODEL_FILE (ctx=$CTX ngl=$NGL kv=$KV)"
echo "URL: http://$HOST:$PORT  OpenAI-compatible: http://127.0.0.1:$PORT/v1"
echo "Cloudflared example: cloudflared tunnel --url http://127.0.0.1:$PORT"
[[ "$HOST" == "0.0.0.0" ]] && echo "WARNING: bound to LAN. Prefer HOST=127.0.0.1 for tunnel-only use."
pkill -f llama-server || true
sleep 1
exec "$BIN" -m "$DIR/$MODEL_DIR/$MODEL_FILE" -c "$CTX" -ngl "$NGL" -ctk "$KV" -ctv "$KV" \
  -fa on --prio 2 --parallel 1 -t 8 -tb 12 --host "$HOST" \
  --reasoning-effort medium --reasoning-budget 512 --alias "Local Model" --port "$PORT" \
  "${KEY_ARGS[@]}" "${SPEC_ARGS[@]}"
