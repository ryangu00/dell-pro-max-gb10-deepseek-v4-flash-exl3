#!/usr/bin/env bash
# Deploy the recorded single-seat recipe on Dell Pro Max with GB10.
set -euo pipefail

# Recorded recipe pins in the README; the original August image digest is open.
readonly LAUNCHER_REPO=https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark
readonly LAUNCHER_COMMIT=fdcd538fbf95fb15b2d6850db9613d22b2c889b8
readonly IMAGE=ghcr.io/0xsero/deepseek-v4-flash-0731-spark-sparkinfer@sha256:2e077489a83a0360952828051fe7f7a32c1801e5ce8436d85f7267583d614ff4
readonly MODEL_REPO=0xSero/deepseek-v4-flash-0731-spark
readonly MODEL_REVISION=22f28d32b9b29b4352eaa380ff8c2c170b2847ab

PORT=8888
HOST=127.0.0.1
DRY_RUN=0
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
STATE_DIR="$ROOT/.deploy"
LAUNCHER_DIR="$STATE_DIR/launcher"
MEMINFO_PATH=${MEMINFO_PATH:-/proc/meminfo}
readonly SERVED_MODEL=deepseek-v4-flash-0731

say() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] FAIL: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "need $1"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --port|--host)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
      case "$1" in --port) PORT=$2;; --host) HOST=$2;; esac
      shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --help) echo 'Usage: scripts/deploy.sh [--port N] [--host ADDR] [--dry-run]'; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

need python3
API_URL=$(python3 - "$HOST" "$PORT" <<'PY'
import ipaddress
import sys

host, port = sys.argv[1:]
if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
    sys.exit("port must be an integer from 1 to 65535")
if host != "localhost":
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        sys.exit("host must be a numeric bind address or localhost")
    if not address.is_loopback:
        print("[deploy] WARNING: the API has no authentication on this bind address.", file=sys.stderr)
    if address.is_unspecified:
        host = "127.0.0.1"
    elif address.version == 6:
        host = f"[{host}]"
print(f"http://{host}:{int(port)}")
PY
) || die 'invalid host or port'
PORT=$((10#$PORT))

resolved() {
  printf '%s\n' \
    "LAUNCHER_REPO=$LAUNCHER_REPO" "LAUNCHER_COMMIT=$LAUNCHER_COMMIT" \
    "IMAGE=$IMAGE" "MODEL_REPO=$MODEL_REPO" "MODEL_REVISION=$MODEL_REVISION" \
    "SERVING_HOST=$HOST" "SERVING_PORT=$PORT" \
    'MAX_MODEL_LEN=384000' 'MAX_NUM_SEQS=1' 'MAX_NUM_BATCHED_TOKENS=8224' \
    'GPU_MEMORY_UTILIZATION=0.94' 'KV_RECORD=stock432' 'MODE=dspark' \
    'VERIFY_MODEL_CHECKSUMS=1' 'ABLATE=0'
}

# Offline gates also run in dry-run mode, without invoking Docker or Git.
case "$(uname -m)" in aarch64|arm64) ;; *) die 'this recipe requires arm64';; esac
need pgrep
if pgrep -x earlyoom >/dev/null; then
  die 'earlyoom is running; refusing to start (it has not been stopped)'
else
  status=$?
  [ "$status" -eq 1 ] || die 'could not check whether earlyoom is running'
fi
check_memory() {
  python3 - "$MEMINFO_PATH" <<'PY'
from decimal import Decimal
from pathlib import Path
import sys

try:
    fields = [line.split() for line in Path(sys.argv[1]).read_text().splitlines()
              if line.startswith("MemAvailable:")]
    if len(fields) != 1 or len(fields[0]) != 3 or fields[0][2] != "kB":
        raise ValueError
    available = int(fields[0][1])
    if available < Decimal("114.3") * 1024 * 1024:
        sys.exit("[deploy] FAIL: MemAvailable must be at least 114.3 GiB before start")
except (OSError, ValueError):
    sys.exit("[deploy] FAIL: cannot read a valid MemAvailable from MEMINFO_PATH")
PY
}
check_disk() {
  local free_kib
  free_kib=$(LC_ALL=C df -Pk "$ROOT" | awk 'END {print $4}')
  [[ "$free_kib" =~ ^[0-9]+$ ]] || die 'cannot determine free disk space'
  [ "$free_kib" -ge 230686720 ] || die 'need at least 220 GiB free disk before start'
}
if [ "$DRY_RUN" -eq 1 ]; then
  check_memory
  check_disk
  resolved
  say 'offline preflight passed; Docker, GPU, pins and readiness were not checked'
  exit 0
fi

# A saved request only permits inspection of an existing container. It is not
# proof of readiness. A new start must pass the resource gates again below.
if [ ! -f "$STATE_DIR/requested.env" ]; then
  check_memory
  check_disk
fi
for tool in docker git curl; do need "$tool"; done
docker info --format '{{json .Runtimes}}' | python3 -c '
import json, sys
sys.exit(0 if "nvidia" in json.load(sys.stdin) else 1)
' || die 'Docker must be running with the NVIDIA container runtime'

mkdir -p "$STATE_DIR"
if [ ! -d "$LAUNCHER_DIR" ]; then
  git clone "$LAUNCHER_REPO" "$LAUNCHER_DIR"
fi
(
  cd "$LAUNCHER_DIR"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die 'launcher checkout has local changes'
  git checkout "$LAUNCHER_COMMIT"
  [ "$(git rev-parse HEAD)" = "$LAUNCHER_COMMIT" ] || die 'launcher commit mismatch'
)

# Read literal shell defaults without executing the launcher during validation.
# An unrecognized or ambiguous default fails closed and needs manual review.
python3 - "$LAUNCHER_DIR" "${IMAGE##*@}" "$MODEL_REVISION" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1])
scripts = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-z", "--", "*.sh"]
).decode().strip("\0").split("\0")
for name, expected in zip(("IMAGE_DIGEST", "MODEL_REVISION"), sys.argv[2:]):
    values = set()
    for script in filter(None, scripts):
        for line in (root / script).read_text().splitlines():
            match = re.match(r"^\s*(?:(?:export|readonly)\s+)?" + name + r"=(.*)$", line)
            if not match:
                continue
            value = match[1].split(" #", 1)[0].strip().strip("\"'")
            default = re.fullmatch(r"\$\{" + name + r":?[-=](.*?)\}", value)
            if default:
                value = default[1].strip("\"'")
            values.add(value)
    if values != {expected}:
        sys.exit(f"[deploy] FAIL: launcher {name} default missing, ambiguous or mismatched")
PY

export SERVING_HOST="$HOST" SERVING_PORT="$PORT"
export MAX_MODEL_LEN=384000 MAX_NUM_SEQS=1 MAX_NUM_BATCHED_TOKENS=8224
export GPU_MEMORY_UTILIZATION=0.94 KV_RECORD=stock432 MODE=dspark
export VERIFY_MODEL_CHECKSUMS=1 ABLATE=0
export IMAGE_DIGEST="${IMAGE##*@}" MODEL_REVISION MODEL_REPO

# Discover ownership from Compose metadata, without guessing a container name.
container_id() {
  local ids id
  ids=$(docker ps -aq --filter label=com.docker.compose.project.working_dir) || return 1
  [ -n "$ids" ] || return 0
  # Read Docker IDs into an array so only word splitting, not globbing, applies.
  local -a containers=()
  while IFS= read -r id; do containers+=("$id"); done <<< "$ids"
  docker inspect "${containers[@]}" | python3 -c '
import json, os, sys
root, image = sys.argv[1:]
matches = []
for item in json.load(sys.stdin):
    labels = item["Config"].get("Labels") or {}
    directory = labels.get("com.docker.compose.project.working_dir", "")
    if directory and (directory == root or directory.startswith(root + os.sep)):
        if item["Config"]["Image"] == image:
            matches.append(item["Id"])
if len(matches) > 1:
    sys.exit("[deploy] FAIL: multiple launcher containers; cannot choose safely")
if matches:
    print(matches[0])
' "$LAUNCHER_DIR" "$IMAGE"
}
running() { [ "$(docker inspect --format '{{.State.Running}}' "$1")" = true ]; }
models_match() {
  curl --noproxy '*' -fsS --max-time 5 "$API_URL/v1/models" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    valid = any(item.get("id") == sys.argv[1] for item in data.get("data", []))
except (ValueError, TypeError, AttributeError):
    valid = False
sys.exit(0 if valid else 1)
' "$SERVED_MODEL"
}

CID=$(container_id) || die 'cannot identify the launcher container'
SKIP_START=0
if [ -n "$CID" ]; then
  if running "$CID" && cmp -s "$STATE_DIR/requested.env" <(resolved) && models_match; then
    SKIP_START=1
    say 'matching container is running; skipping start'
  else
    say 'container stopped or configuration changed; running down before a fresh start'
    (cd "$LAUNCHER_DIR" && ./start.sh down)
    running "$CID" 2>/dev/null && die 'launcher container is still running after down'
  fi
fi

START_PID=''
cleanup() {
  if [ -n "$START_PID" ]; then kill "$START_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
DEADLINE=$((SECONDS + 2700))
if [ "$SKIP_START" -eq 0 ]; then
  check_memory
  check_disk
  docker pull "$IMAGE"
  docker image inspect "$IMAGE" | python3 -c '
import json, sys
sys.exit(0 if sys.argv[1] in json.load(sys.stdin)[0].get("RepoDigests", []) else 1)
' "$IMAGE" || die 'pulled image digest mismatch'
  docker run --rm --gpus all --entrypoint nvidia-smi "$IMAGE" -L \
    | grep -q '^GPU ' || die 'no GPU visible inside the pinned container'
  resolved > "$STATE_DIR/requested.env"
  say 'starting launcher; first boot can take 40+ minutes'
  DEADLINE=$((SECONDS + 2700))
  (cd "$LAUNCHER_DIR" && exec ./start.sh) > "$STATE_DIR/launcher.log" 2>&1 &
  START_PID=$!
fi

READY=0
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if [ -n "$START_PID" ] && ! kill -0 "$START_PID" 2>/dev/null; then
    wait "$START_PID" || die 'launcher failed; see .deploy/launcher.log'
    START_PID=''
  fi
  CID=$(container_id) || die 'cannot identify the launcher container'
  if [ -n "$CID" ]; then
    status=$(docker inspect --format '{{.State.Status}}' "$CID")
    case "$status" in
      running)
        if curl --noproxy '*' -fsS --max-time 5 "$API_URL/health" >/dev/null && models_match; then
          if [ -z "$START_PID" ]; then READY=1; break; fi
        fi;;
      created) ;; # Compose may have created the container but not started it yet.
      *) die 'launcher container exited or stopped before readiness; see .deploy/launcher.log';;
    esac
  elif [ -z "$START_PID" ]; then
    die 'launcher returned without an identifiable container; see .deploy/launcher.log'
  fi
  sleep 5
done
[ "$READY" -eq 1 ] || die 'not ready after 45 minutes; see .deploy/launcher.log'

RESP=$(curl --noproxy '*' -fsS --max-time 120 "$API_URL/v1/chat/completions" \
  -H 'Content-Type: application/json' -d '{
    "model":"deepseek-v4-flash-0731", "max_tokens":32,
    "chat_template_kwargs":{"thinking":false},
    "messages":[{"role":"user","content":"Reply with exactly DEPLOY_OK"}]
  }') || die 'completion request failed'
printf '%s' "$RESP" | python3 -c '
import json, sys
try:
    content = json.load(sys.stdin)["choices"][0]["message"]["content"]
    valid = isinstance(content, str) and bool(content.strip()) and "DEPLOY_OK" in content
except (ValueError, KeyError, IndexError, TypeError):
    valid = False
sys.exit(0 if valid else 1)
' || die 'completion content is empty or missing DEPLOY_OK'
say 'inference assertion passed; single-seat service ready'
