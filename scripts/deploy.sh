#!/usr/bin/env bash
# deploy.sh — DeepSeek V4 Flash EXL3 single-seat deep workstation, one-command deploy (includes exllamav3 source build)
# Usage: ./deploy.sh [--port 8888] [--ctx 384000] [--models-dir ~/models]
set -euo pipefail
PORT=8888; CTX=384000; MODELS_DIR="$HOME/models"
while [ $# -gt 0 ]; do case "$1" in
  --port) PORT="$2"; shift 2;;
  --ctx) CTX="$2"; shift 2;;
  --models-dir) MODELS_DIR="$2"; shift 2;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done
say() { printf '\033[1m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[deploy] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. Preflight ──
[ "$(uname -m)" = "aarch64" ] || die "this recipe targets aarch64 (Dell Pro Max with GB10)"
python3 -c "import torch; assert torch.cuda.is_available()" 2>/dev/null || die "need PyTorch with CUDA (install the official aarch64 wheel first)"
LOGDIR="$HOME/.cache/exl3-serve"; mkdir -p "$LOGDIR"
if [ -f "$LOGDIR/server-$PORT.pid" ] && kill -0 "$(cat "$LOGDIR/server-$PORT.pid" 2>/dev/null)" 2>/dev/null; then
  SKIP_START=1   # idempotency check runs before the port check
else
  SKIP_START=0
  lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "port $PORT is taken by another process"
fi

# ── 2. exllamav3 build (pitfall #2: arch must be explicit, or the error only surfaces at runtime) ──
if ! python3 -c "import exllamav3" 2>/dev/null; then
  say "building exllamav3 from source (TORCH_CUDA_ARCH_LIST=12.1a explicit, pitfall #2)"
  command -v git >/dev/null || die "need git"
  BUILD_DIR="${EXL3_SRC:-$HOME/build/exllamav3}"
  [ -d "$BUILD_DIR" ] || git clone https://github.com/turboderp-org/exllamav3 "$BUILD_DIR"
  # Reproducibility: EXL3_COMMIT=<sha> pins to a verified commit; default is latest (if the build fails, try pinning a stable tag first)
  [ -z "${EXL3_COMMIT:-}" ] || ( cd "$BUILD_DIR" && git checkout "$EXL3_COMMIT" )
  ( cd "$BUILD_DIR" && TORCH_CUDA_ARCH_LIST="12.1a" pip install -v --no-build-isolation . ) \
    || die "build failed. Check that CUDA toolkit and torch versions match; see the official exllamav3 build docs"
else
  say "exllamav3 already importable, skipping build"
fi

# ── 3. Weights (EXL3 3.0bpw quantized; community-converted or convert your own) ──
W="$MODELS_DIR/DeepSeek-V4-Flash-EXL3-3.0bpw"
[ -d "$W" ] || die "missing weights dir $W. Download an EXL3 3.0bpw conversion (search HF for 'DeepSeek V4 Flash exl3'), or convert your own with exllamav3's convert; put it in place and rerun"

# ── 4. Start (single-seat semantics; maxTokens 65536 = the lesson from two burn-throughs) ──
say "starting EXL3 server @ :$PORT (single-seat, ctx=$CTX; generation cap 65536 — pitfall #1: peak thinking 30k+ tok)"
if [ "${SKIP_START:-0}" = 1 ]; then
  say "instance already running, skipping to liveness check (idempotent)"
else
  nohup python3 -m exllamav3.server --model "$W" --port "$PORT" \
    --max-seq-len "$CTX" --max-new-tokens 65536 > "$LOGDIR/server-$PORT.log" 2>&1 &
  echo $! > "$LOGDIR/server-$PORT.pid"
fi
ok=0
for i in $(seq 1 60); do curl -s -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ok=1; break; }; sleep 10; done
[ "$ok" = 1 ] || die "not ready after 10 minutes, check $LOGDIR/server-$PORT.log"

# ── 5. Real inference assertion ──
RESP=$(curl -s -m 120 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' -d '{
  "model":"exl3","max_tokens":50,"messages":[{"role":"user","content":"Reply with one word: DEPLOY_OK"}]}')
echo "$RESP" | grep -q "DEPLOY_OK" || die "inference assertion failed: $(echo "$RESP" | head -c 300)"
say "✅ deep workstation ready: http://127.0.0.1:$PORT/v1 (single-seat — put a queue/semaphore on the caller side, pitfall #3)"
