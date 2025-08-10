#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
: "${COMFYUI_ROOT:=/mnt/netdrive/comfyui}"
: "${VENV_ROOT:=/mnt/netdrive/python_envs}"
: "${PIP_CACHE_DIR:=/mnt/netdrive/pip_cache}"
: "${TMPDIR:=/mnt/netdrive/tmp}"
: "${LEGACY_VENV:=/mnt/netdrive/python_env}"
: "${JUPYTER_CONFIG_DIR:=/mnt/netdrive/config/jupyter}"

# Add after config section (line 10):
# Hopper/Ada compatibility settings
export XFORMERS_DISABLE_FLASH_ATTN="${XFORMERS_DISABLE_FLASH_ATTN:-0}"
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
export CUDA_MODULE_LOADING=LAZY

# Check GPU architecture and set flags
GPU_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d '.' || echo "0")
if [[ "$GPU_ARCH" =~ ^[0-9]+$ ]] && [[ "$GPU_ARCH" -ge "90" ]]; then
  echo "[INFO] Hopper/Ada GPU detected, setting compatibility flags"
  export XFORMERS_DISABLE_FLASH_ATTN=1
fi

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
GPU_CC_MIN="${GPU_CC_RAW##*.}"
GPU_CC_NUM=$((GPU_CC_MAJ * 10 + GPU_CC_MIN))

echo "[INFO] GPU Compute Capability: ${GPU_CC_RAW:-unknown}"

if [[ -n "$GPU_CC_RAW" ]]; then
  # sm_120 = CC 12.0 (RTX 5090)
  # sm_90 = CC 9.0 (RTX 4090)
  if (( GPU_CC_NUM >= 120 )); then 
    CU_TAG="cu128"
    GPU_ARCH="sm_120"
  elif (( GPU_CC_NUM >= 90 )); then 
    CU_TAG="cu124"
    GPU_ARCH="sm_90"
  elif (( GPU_CC_NUM >= 86 )); then 
    CU_TAG="cu121"
    GPU_ARCH="sm_86"
  else 
    CU_TAG="cu118"
    GPU_ARCH="sm_80"
  fi
else
  CU_TAG="cpu"
  GPU_ARCH="cpu"
fi

echo "[INFO] GPU Architecture: ${GPU_ARCH}, CUDA Tag: ${CU_TAG}"

# Use GPU architecture specific venv
VENV_PATH="${VENV_ROOT}/${GPU_ARCH}_${CU_TAG}"
echo "[VENV] Using venv path: $VENV_PATH"

# Ensure venv exists in network volume
if [ ! -d "$VENV_PATH" ] || [ ! -f "$VENV_PATH/bin/python" ]; then
  echo "[VENV] Creating new venv at $VENV_PATH for ${GPU_ARCH}"
  rm -rf "$VENV_PATH" 2>/dev/null || true
  mkdir -p "$VENV_PATH"
  python3.12 -m venv "$VENV_PATH" --upgrade-deps
  
  # Verify venv creation
  if [ ! -f "$VENV_PATH/bin/python" ]; then
    echo "[ERROR] Failed to create venv at $VENV_PATH"
    exit 1
  fi
fi

# Update legacy symlink to current venv
if [ -L "$LEGACY_VENV" ]; then
  rm -f "$LEGACY_VENV"
fi
ln -sfn "$VENV_PATH" "$LEGACY_VENV"

# Activate venv
source "$VENV_PATH/bin/activate"
PYBIN="$VENV_PATH/bin/python"
PIPBIN="$VENV_PATH/bin/pip"
export PATH="$VENV_PATH/bin:$PATH"

$PIPBIN install --upgrade pip wheel setuptools
echo "[INFO] Using Python: $($PYBIN --version)"

# ---- PyTorch 2.8 Installation ----
TORCH_VER="2.8.0"

# Set correct index URLs for PyTorch 2.8
case "$CU_TAG" in
  cu128)
    # For CUDA 12.8 (RTX 5090)
    TORCH_URL="https://download.pytorch.org/whl/cu128"
    TORCH_SUFFIX="cu128"
    TVISION_VER="0.23.0"
    ;;
  cu124)
    # For CUDA 12.4 (RTX 4090)
    TORCH_URL="https://download.pytorch.org/whl/cu124" 
    TORCH_SUFFIX="cu124"
    TVISION_VER="0.23.1"
    ;;
  cu121)
    TORCH_URL="https://download.pytorch.org/whl/cu121"
    TORCH_SUFFIX="cu121"
    TVISION_VER="0.23.1"
    ;;
  cu118)
    TORCH_URL="https://download.pytorch.org/whl/cu118"
    TORCH_SUFFIX="cu118"
    TVISION_VER="0.23.1"
    ;;
  cpu)
    TORCH_URL="https://download.pytorch.org/whl/cpu"
    TORCH_SUFFIX="cpu"
    TVISION_VER="0.23.1"
    ;;
esac

echo "[TORCH] Target: torch==${TORCH_VER}+${TORCH_SUFFIX}, torchvision==${TVISION_VER}+${TORCH_SUFFIX}"

# Check current torch version
CURRENT_TORCH=$("$PYBIN" -c "import torch; print(torch.__version__)" 2>/dev/null || echo "none")
EXPECTED_TORCH="${TORCH_VER}+${CU_TAG}"

if [[ "$CURRENT_TORCH" != "$EXPECTED_TORCH" ]]; then
  echo "[TORCH] Current: $CURRENT_TORCH, Expected: $EXPECTED_TORCH"
  echo "[TORCH] Installing torch==${TORCH_VER}+${CU_TAG}, torchvision==${TVISION_VER}+${CU_TAG}"
  
  # Clean uninstall
  "$PIPBIN" uninstall -y torch torchvision torchaudio xformers 2>/dev/null || true
  
  # Install with --force-reinstall and --no-deps first
  "$PIPBIN" install --no-cache-dir --no-deps --force-reinstall \
    --extra-index-url "$TORCH_URL" \
    torch=="${TORCH_VER}+${CU_TAG}" \
    torchvision=="${TVISION_VER}+${CU_TAG}"
    
  # Then install dependencies
  "$PIPBIN" install --no-cache-dir \
    filelock typing-extensions sympy networkx jinja2 fsspec numpy pillow
else
  echo "[TORCH] Correct version already installed: $CURRENT_TORCH"
fi

# --- xFormers Installation ---
# แทนที่ทั้งหมดด้วย:
if [ "$CU_TAG" != "cpu" ]; then
  # Install xformers WITHOUT letting it change torch version
  XFORMERS_CHECK=$("$PYBIN" -c "import xformers; print('installed')" 2>/dev/null || echo "not_installed")
  
  if [ "$XFORMERS_CHECK" = "not_installed" ]; then
    echo "[XFORMERS] Installing with torch ${TORCH_VER}+${CU_TAG} locked"
    
    # Method 1: Try installing with --no-deps first
  if ! "$PIPBIN" install --no-cache-dir --no-deps \
    --extra-index-url "$TORCH_URL" xformers 2>/dev/null; then
  
    echo "[XFORMERS] Method 1 failed, trying alternative installation method"
  
    # Method 2: Install with constraint file
      echo "torch==${TORCH_VER}+${CU_TAG}" > /tmp/constraints.txt
      if ! "$PIPBIN" install --no-cache-dir \
        --constraint /tmp/constraints.txt \
        --extra-index-url "$TORCH_URL" xformers; then
      
      echo "[WARNING] xFormers installation failed, continuing without it"
      rm -f /tmp/constraints.txt
    else
      rm -f /tmp/constraints.txt
    fi
  fi
  
  # Verify torch wasn't downgraded
  TORCH_AFTER=$("$PYBIN" -c "import torch; print(torch.__version__)" 2>/dev/null)
  if [[ "$TORCH_AFTER" != "${TORCH_VER}+${CU_TAG}" ]]; then
    echo "[WARNING] Torch was changed to $TORCH_AFTER, reinstalling correct version"
    "$PIPBIN" install --no-cache-dir --force-reinstall --no-deps \
      --extra-index-url "$TORCH_URL" \
      torch=="${TORCH_VER}+${CU_TAG}"
  fi
  
  # Test xformers with Hopper workaround
  echo "[XFORMERS] Testing..."
  "$PYBIN" - <<'PY' 2>&1 | grep -E "^\[XFORMERS\]" || true
import sys
try:
    import torch
    import xformers
    print(f"[XFORMERS] Version: {xformers.__version__}")
    print(f"[XFORMERS] Torch: {torch.__version__}")
    
    # For Hopper (sm_90+), flash attention might fail
    if torch.cuda.is_available():
        cap = torch.cuda.get_device_capability()
        if cap[0] >= 9:
            print(f"[XFORMERS] Hopper/Ada architecture detected (sm_{cap[0]}{cap[1]})")
            print("[XFORMERS] Flash attention may show errors - this is expected")
            # Set environment variable to disable flash attention
            import os
            os.environ['XFORMERS_DISABLE_FLASH_ATTN'] = '1'
            print("[XFORMERS] Disabled flash attention for compatibility")
except Exception as e:
    print(f"[XFORMERS] Import error: {e}")
PY
fi

# --- app deps (skip torch/xformers) ---
# แทนที่ด้วย:
REQ="${COMFYUI_DIR}/requirements.txt"
if [ -f "$REQ" ]; then
  echo "[PIP] Installing app deps (torch locked at ${TORCH_VER}+${CU_TAG})"
  
  # Create constraints file to lock torch version
  cat > /tmp/constraints.txt <<EOF
torch==${TORCH_VER}+${CU_TAG}
torchvision==${TVISION_VER}+${CU_TAG}
EOF
  
  # Filter out torch packages from requirements
  grep -viE '^(torch|torchvision|torchaudio|xformers)' "$REQ" > /tmp/req-notorch.txt || true
  
  if [ -s /tmp/req-notorch.txt ]; then
    "$PIPBIN" install --no-cache-dir \
      --constraint /tmp/constraints.txt \
      -r /tmp/req-notorch.txt || true
  fi
  
  rm -f /tmp/req-notorch.txt /tmp/constraints.txt
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
