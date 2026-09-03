#!/usr/bin/env bash
# deploy.sh — DeepSeek V4 Flash EXL3 单座深工位一键部署(含 exllamav3 源码构建)
# 用法: ./deploy.sh [--port 8888] [--ctx 384000] [--models-dir ~/models]
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

# ── 1. 预检 ──
[ "$(uname -m)" = "aarch64" ] || die "本配方面向 aarch64(Dell Pro Max with GB10)"
python3 -c "import torch; assert torch.cuda.is_available()" 2>/dev/null || die "需要带 CUDA 的 PyTorch(先装官方 aarch64 wheel)"
LOGDIR="$HOME/.cache/exl3-serve"; mkdir -p "$LOGDIR"
if [ -f "$LOGDIR/server-$PORT.pid" ] && kill -0 "$(cat "$LOGDIR/server-$PORT.pid" 2>/dev/null)" 2>/dev/null; then
  SKIP_START=1   # 幂等判定先于端口检查
else
  SKIP_START=0
  lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "端口 $PORT 被其他进程占用"
fi

# ── 2. exllamav3 构建(坑 #2:arch 必须显式,否则运行时才爆) ──
if ! python3 -c "import exllamav3" 2>/dev/null; then
  say "源码构建 exllamav3(TORCH_CUDA_ARCH_LIST=12.1a 显式,坑 #2)"
  command -v git >/dev/null || die "需要 git"
  BUILD_DIR="${EXL3_SRC:-$HOME/build/exllamav3}"
  [ -d "$BUILD_DIR" ] || git clone https://github.com/turboderp-org/exllamav3 "$BUILD_DIR"
  # 可复现性:EXL3_COMMIT=<sha> 可 pin 到已验证 commit;默认最新(构建失败先试 pin 稳定 tag)
  [ -z "${EXL3_COMMIT:-}" ] || ( cd "$BUILD_DIR" && git checkout "$EXL3_COMMIT" )
  ( cd "$BUILD_DIR" && TORCH_CUDA_ARCH_LIST="12.1a" pip install -v --no-build-isolation . ) \
    || die "构建失败。检查 CUDA toolkit 与 torch 版本匹配;详见 exllamav3 官方构建文档"
else
  say "exllamav3 已可导入,跳过构建"
fi

# ── 3. 权重(EXL3 3.0bpw 量化版;社区转换或自转) ──
W="$MODELS_DIR/DeepSeek-V4-Flash-EXL3-3.0bpw"
[ -d "$W" ] || die "缺权重目录 $W。下载 EXL3 3.0bpw 转换版(社区 HF 搜 'DeepSeek V4 Flash exl3'),或用 exllamav3 的 convert 自转;放好后重跑"

# ── 4. 启动(单座语义;maxTokens 65536=烧穿两次的教训) ──
say "启动 EXL3 服务 @ :$PORT(单座,ctx=$CTX;生成上限 65536——坑 #1:思考峰值 3 万+ tok)"
if [ "${SKIP_START:-0}" = 1 ]; then
  say "已有实例在跑,跳到验活(幂等)"
else
  nohup python3 -m exllamav3.server --model "$W" --port "$PORT" \
    --max-seq-len "$CTX" --max-new-tokens 65536 > "$LOGDIR/server-$PORT.log" 2>&1 &
  echo $! > "$LOGDIR/server-$PORT.pid"
fi
ok=0
for i in $(seq 1 60); do curl -s -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ok=1; break; }; sleep 10; done
[ "$ok" = 1 ] || die "10 分钟未就绪,看 $LOGDIR/server-$PORT.log"

# ── 5. 真实推理断言 ──
RESP=$(curl -s -m 120 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' -d '{
  "model":"exl3","max_tokens":50,"messages":[{"role":"user","content":"回复一个词:DEPLOY_OK"}]}')
echo "$RESP" | grep -q "DEPLOY_OK" || die "推理断言失败: $(echo "$RESP" | head -c 300)"
say "✅ 深工位就绪: http://127.0.0.1:$PORT/v1(单座——调用侧放队列/信号量,坑 #3)"
