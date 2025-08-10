#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
: "${COMFYUI_ROOT:=/mnt/netdrive/comfyui}"
: "${VENV_ROOT:=/mnt/netdrive/python_envs}"
: "${PIP_CACHE_DIR:=/mnt/netdrive/pip_cache}"
: "${TMPDIR:=/mnt/netdrive/tmp}"
: "${LEGACY_VENV:=/mnt/netdrive/python_env}"
: "${JUPYTER_CONFIG_DIR:=/mnt/netdrive/config/jupyter}"

# --- Normalize ENV values ---
# Normalize ENABLE_JUPYTER (accept true/1/yes/enable as true)
: "${ENABLE_JUPYTER:=false}"
case "${ENABLE_JUPYTER,,}" in
  true|1|yes|enable) ENABLE_JUPYTER=true ;;
  *)                 ENABLE_JUPYTER=false ;;
esac

# --- Network caches (opt-in บางตัว) ---
DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo unknown)"
CACHE_ROOT="/mnt/netdrive/cache/${CU_TAG}_${DRV}"

# --- Derived paths ---
export COMFYUI_DIR="$COMFYUI_ROOT"
export COMFYUI_CUSTOM_NODES="$COMFYUI_DIR/custom_nodes"
export COMFYUI_MODELS="$COMFYUI_DIR/models"

# --- Create required dirs ---
mkdir -p "$PIP_CACHE_DIR" "$TMPDIR" "$VENV_ROOT" "$COMFYUI_ROOT"

unset PIP_INDEX_URL || true
unset PIP_EXTRA_INDEX_URL || true
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_CONFIG_FILE=/dev/null

echo "[BOOT] Host driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 || echo 'unknown')"

# --- Detect CUDA -> CU_TAG ---
GPU_CC_RAW="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n1 || true)"
GPU_CC_MAJ="${GPU_CC_RAW%%.*}"
if [[ -n "$GPU_CC_RAW" ]]; then
  if (( GPU_CC_MAJ >= 12 )); then CU_TAG="cu128"
  elif (( GPU_CC_MAJ >= 9 )); then CU_TAG="cu126"
  else CU_TAG="cu124"
  fi
else
  CU_TAG="cpu"
fi
echo "[INFO] GPU Compute Capability: ${GPU_CC_RAW:-unknown} → CU_TAG=$CU_TAG"

# --- Per-CUDA venv + symlink (/mnt/netdrive/python_env -> current venv) ---
VENV_PATH="${VENV_ROOT}/${CU_TAG}"
if [ ! -d "$VENV_PATH" ]; then
  echo "[VENV] Creating venv at $VENV_PATH"
  python3 -m venv "$VENV_PATH"
fi
# refresh legacy symlink
if [ ! -L "$LEGACY_VENV" ] || [ "$(readlink -f "$LEGACY_VENV")" != "$VENV_PATH" ]; then
  rm -rf "$LEGACY_VENV" 2>/dev/null || true
  ln -s "$VENV_PATH" "$LEGACY_VENV"
fi

# Activate venv
source "$VENV_PATH/bin/activate"
PYBIN="$VENV_PATH/bin/python"
PIPBIN="$VENV_PATH/bin/pip"
export PATH="$VENV_PATH/bin:$PATH"

$PIPBIN install --upgrade pip wheel setuptools
echo "[INFO] Using Python: $($PYBIN --version)"

# ---- desired versions ----
TORCH_VER="2.8.0"
case "$CU_TAG" in
  cu128) TORCH_URL="https://download.pytorch.org/whl/cu128" ;;
  cu126) TORCH_URL="https://download.pytorch.org/whl/cu126" ;;
  cu124) TORCH_URL="https://download.pytorch.org/whl/cu124" ;;
  cpu)   TORCH_URL="https://download.pytorch.org/whl/cpu" ;;
esac


# pick torchvision to match torch 2.8
case "$TORCH_VER" in
  2.8.*)
    if [ "$CU_TAG" = "cu128" ]; then
      TVISION_VER="0.23.0"
    else
      TVISION_VER="0.23.1"
    fi
    ;;
  2.7.*) TVISION_VER="0.19.1" ;;
  *)     TVISION_VER="0.23.1" ;;
esac

# install if missing
if ! "$PYBIN" - <<'PY'
import sys
try:
    import torch; print("found torch", torch.__version__); sys.exit(0)
except Exception:
    sys.exit(1)
PY
then
  echo "[TORCH] Installing torch==${TORCH_VER}+${CU_TAG}, torchvision==${TVISION_VER}+${CU_TAG}"
  "$PIPBIN" install --only-binary=:all: --extra-index-url "$TORCH_URL" \
    "torch==${TORCH_VER}+${CU_TAG}" "torchvision==${TVISION_VER}+${CU_TAG}"
fi

# verify GPU runtime
if [ "$CU_TAG" != "cpu" ]; then
  "$PYBIN" - <<'PY'
import sys, torch
assert torch.cuda.is_available(), "CUDA not available"
x=torch.randn(512,512,device="cuda").half(); y=torch.randn(512,512,device="cuda").half()
torch.matmul(x,y); torch.cuda.synchronize()
print("[TORCH] OK:", torch.__version__, "CUDA", torch.version.cuda)
PY
else
  echo "[TORCH] CPU-only mode detected; skipping CUDA check."
fi

# --- xFormers: REQUIRED, wheel-only (no source build), fail fast if not usable ---
if [ "$CU_TAG" != "cpu" ]; then
  if ! "$PYBIN" - <<'PY'
import sys
try:
    import torch, xformers, xformers.ops as xo
    q=torch.randn(1,4,64,64,device="cuda",dtype=torch.float16)
    k=torch.randn(1,4,64,64,device="cuda",dtype=torch.float16)
    v=torch.randn(1,4,64,64,device="cuda",dtype=torch.float16)
    xo.memory_efficient_attention(q,k,v); torch.cuda.synchronize()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
  then
    echo "[XFORMERS] Installing wheel for ${CU_TAG}"
    "$PIPBIN" install --only-binary=:all: --extra-index-url "$TORCH_URL" xformers
    echo "[XFORMERS] Verifying..."
    "$PYBIN" - <<'PY'
import sys, torch, xformers, xformers.ops as xo
assert torch.cuda.is_available(), "CUDA not available"
q=torch.randn(1,4,64,64,device="cuda",dtype=torch.float16)
k=torch.randn(1,4,64,64,device="cuda",dtype=torch.float16)
v=torch.randn(1,4,64,64,device="cuda",dtype=torch.float16)
xo.memory_efficient_attention(q,k,v); torch.cuda.synchronize()
print("[XFORMERS] OK")
PY
  fi
else
  echo "[XFORMERS] Skipped (CPU-only mode)."
fi

# --- app deps (skip torch/xformers) ---
REQ="${COMFYUI_DIR}/requirements.txt"
if [ -f "$REQ" ]; then
  echo "[PIP] Installing app deps (preserve torch/xformers)"
  grep -viE '^(torch|torchvision|torchaudio|xformers)(==|>=|<=|$)' "$REQ" > /tmp/req-notorch.txt || true
  if [ -s /tmp/req-notorch.txt ]; then
    "$PIPBIN" install -r /tmp/req-notorch.txt
  fi
fi

# ตรวจสอบว่ามีโฟลเดอร์ ComfyUI หรือไม่ ถ้าไม่มีก็ clone
if [ ! -d "$COMFYUI_DIR" ] || [ -z "$(ls -A "$COMFYUI_DIR" 2>/dev/null)" ]; then
  echo "[ENTRYPOINT] ComfyUI directory not found. Cloning from GitHub..."
    git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
fi

# --- Jupyter (optional; same venv) ---
if [ "$ENABLE_JUPYTER" = "true" ]; then
  echo "[JUPYTER] Enabling JupyterLab on :8888"
  "$PIPBIN" install --no-cache-dir jupyter jupyterlab
  mkdir -p "$JUPYTER_CONFIG_DIR"
  nohup "$PYBIN" -m jupyter lab --ip=0.0.0.0 --port=8888 --no-browser \
    --ServerApp.token='' --ServerApp.password='' \
    --ServerApp.allow_origin='*' --ServerApp.allow_remote_access=True \
    --ServerApp.port_retries=0 --ServerApp.root_dir=/mnt/netdrive \
    > /mnt/netdrive/jupyter.log 2>&1 &
fi

# System Information
echo "[INFO] Using Python: $(which python)"
echo "[INFO] Python version: $(python --version)"

# Debug Checking
echo "[DEBUG] Checking setup_custom_nodes.py..."
if [ -f "/setup_custom_nodes.py" ]; then
    echo "[DEBUG] ✅ File exists"
    ls -la /setup_custom_nodes.py
else
    echo "[DEBUG] ❌ File not found"
    echo "[DEBUG] Files in root directory:"
    ls -la /
    echo "[DEBUG] Current working directory: $(pwd)"
fi

echo "[DEBUG] Checking download_models.py..."
if [ -f "/download_models.py" ]; then
    echo "[DEBUG] ✅ File exists"
    ls -la /download_models.py
else
    echo "[DEBUG] ❌ File not found"
    echo "[DEBUG] Files in root directory:"
    ls -la /
    echo "[DEBUG] Current working directory: $(pwd)"
fi

# Custom Nodes & Models Setup - รันแบบ parallel
echo "[SETUP] Starting parallel custom nodes and models setup..."
echo "[DEBUG] Pre-setup check at $(date)"
echo "[DEBUG] Available disk space:"
df -h /mnt/netdrive
echo "[DEBUG] Memory usage:"
free -h
#echo "[DEBUG] Network status:"

# Add log file for custom nodes and models setup
echo "[SETUP] Starting custom nodes setup..."
"$PYBIN" /setup_custom_nodes.py > /mnt/netdrive/comfyui/setup_custom_nodes.log 2>&1 &
CUSTOM_NODES_PID=$!
echo "[SETUP] Starting models download..."
"$PYBIN" /download_models.py > /mnt/netdrive/comfyui/download_models.log 2>&1 &
DOWNLOAD_MODELS_PID=$!

# เพิ่ม enhanced monitoring
echo "[DEBUG] Enhanced monitoring started..."
monitor_start_time=$(date +%s)
while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - monitor_start_time))
    
    # Check if processes are still running
    if ! kill -0 $CUSTOM_NODES_PID 2>/dev/null && ! kill -0 $DOWNLOAD_MODELS_PID 2>/dev/null; then
        echo "[DEBUG] All processes completed after ${elapsed}s"
        break
    fi
    
    echo "[DEBUG] Processes still running at $(date) (${elapsed}s elapsed)"
    echo "[DEBUG] Custom nodes PID: $CUSTOM_NODES_PID"
    echo "[DEBUG] Download models PID: $DOWNLOAD_MODELS_PID"
    
    # Show process status
    if kill -0 $CUSTOM_NODES_PID 2>/dev/null; then
        echo "[DEBUG] Custom nodes process is alive"
    fi
    if kill -0 $DOWNLOAD_MODELS_PID 2>/dev/null; then
        echo "[DEBUG] Download models process is alive"
    fi
    
    sleep 5
done

# รอให้ทั้งสอง process เสร็จ
wait $CUSTOM_NODES_PID $DOWNLOAD_MODELS_PID 2>/dev/null || true
echo "[DEBUG] All parallel processes completed at $(date)"

# เพิ่ม Process Cleanup
echo "[CLEANUP] Starting process cleanup..."
echo "[DEBUG] Checking for zombie processes..."
ps aux | grep -E "(python|uv|pip)" | grep -v grep || echo "[DEBUG] No zombie processes found"

# Kill any remaining background processes
echo "[CLEANUP] Cleaning up background processes..."
pkill -f "setup_custom_nodes.py" 2>/dev/null || true
pkill -f "download_models.py" 2>/dev/null || true
pkill -f "uv pip install" 2>/dev/null || true

# Clean up temp files
echo "[CLEANUP] Cleaning up temporary files..."
find /tmp -name "*.tmp" -delete 2>/dev/null || true
find /mnt/netdrive/tmp -name "*.tmp" -delete 2>/dev/null || true

# Memory cleanup
echo "[CLEANUP] Memory cleanup..."
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

echo "[DEBUG] Disk usage after parallel setup:"
df -h /
df -h /mnt/netdrive

# Clean up temp after setup
echo "[CLEANUP] Cleaning up /mnt/netdrive/tmp after setup..."
rm -rf /mnt/netdrive/tmp/* || true

# Check GPU availability
if command -v nvidia-smi &> /dev/null; then
  echo "[ENTRYPOINT] GPU detected:"
  nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits | head -3
else
  echo "[ENTRYPOINT] No GPU detected, running in CPU mode"
fi

# Change to ComfyUI directory
cd "$COMFYUI_DIR"

# Set default arguments
ARGS=(
  --listen 0.0.0.0
  --port 8188
  --preview-method auto
)

# Add extra arguments if provided
if [ $# -gt 0 ]; then
  ARGS+=("$@")
fi

# Show memory usage before start
if command -v nvidia-smi &> /dev/null; then
  echo "[ENTRYPOINT] GPU Memory before start at $(date):"
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits
fi

# Add CPU-only flag if no GPU
if ! command -v nvidia-smi &> /dev/null || ! "$PYBIN" -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
  echo "[ENTRYPOINT] Adding --cpu flag (no GPU available)"
  ARGS+=(--cpu)
fi

# ComfyUI startup
echo "[ENTRYPOINT] Starting ComfyUI with args: ${ARGS[*]}"
"$PYBIN" main.py "${ARGS[@]}" 2>&1 | tee /mnt/netdrive/comfyui/main.log &

# Wait for ComfyUI to start
sleep 2
if ! pgrep -f "python.*main.py" > /dev/null; then
    echo "[ERROR] Failed to start ComfyUI (main.py not running)"
    exit 1
fi

# Health check: Main.py
echo "[HEALTHCHECK] Waiting for ComfyUI web UI to be ready..."
MAX_ROUNDS=10
for ((i=1; i<=MAX_ROUNDS; i++)); do
    if curl -s http://127.0.0.1:8188 > /dev/null 2>&1; then
        echo "[HEALTHCHECK] ✅ ComfyUI is up after $((i*30)) seconds."
        break
    fi
    echo "[HEALTHCHECK] ...not ready yet (waited $((i*30)) seconds)"
    sleep 30
done

# Notify if ComfyUI did not start within 10 rounds
if ! curl -s http://127.0.0.1:8188 > /dev/null 2>&1; then
    echo "[HEALTHCHECK] ⚠️  ComfyUI did not start within $((MAX_ROUNDS*30)) seconds."
fi

echo "[ENTRYPOINT] Pod ready"
sleep infinity
