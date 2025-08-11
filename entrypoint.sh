#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
: "${COMFYUI_ROOT:=/mnt/netdrive/comfyui}"
: "${VENV_ROOT:=/mnt/netdrive/python_envs}"
: "${PIP_CACHE_DIR:=/mnt/netdrive/pip_cache}"
: "${TMPDIR:=/mnt/netdrive/tmp}"
: "${LEGACY_VENV:=/mnt/netdrive/python_env}"
: "${JUPYTER_CONFIG_DIR:=/mnt/netdrive/config/jupyter}"

# Service defaults
: "${COMFYUI_HOST:=0.0.0.0}"
: "${COMFYUI_PORT:=8188}"
: "${JUPYTER_PORT:=8888}"
: "${ENABLE_JUPYTER:=true}"
: "${SKIP_XFORMERS:=0}"
: "${XFORMERS_WHEEL_URL:=}"

# Environment
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONNOUSERSITE=1
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
export XFORMERS_DISABLE_FLASH_ATTN=1

# Check mount
if ! grep -qs " /mnt/netdrive " /proc/mounts; then
  echo "[ERROR] /mnt/netdrive not mounted"
  exit 1
fi

mkdir -p "$PIP_CACHE_DIR" "$TMPDIR" "$VENV_ROOT" "$COMFYUI_ROOT" "$JUPYTER_CONFIG_DIR"

# GPU detection
GPU_CC_RAW="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 || true)"
GPU_CC_MAJ="${GPU_CC_RAW%%.*}"
GPU_CC_MIN="${GPU_CC_RAW##*.}"
GPU_CC_NUM=$((GPU_CC_MAJ * 10 + GPU_CC_MIN))

echo "[INFO] GPU Compute Capability: ${GPU_CC_RAW:-unknown}"

if [[ -n "$GPU_CC_RAW" ]]; then
  if (( GPU_CC_NUM >= 120 )); then 
    CU_TAG="cu128"
    GPU_ARCH_NAME="sm_120"
  elif (( GPU_CC_NUM >= 90 )); then 
    CU_TAG="cu124"
    GPU_ARCH_NAME="sm_90"
  elif (( GPU_CC_NUM >= 86 )); then 
    CU_TAG="cu121"
    GPU_ARCH_NAME="sm_86"
  else 
    CU_TAG="cu118"
    GPU_ARCH_NAME="sm_80"
  fi
else
  CU_TAG="cpu"
  GPU_ARCH_NAME="cpu"
fi

echo "[INFO] GPU Architecture: ${GPU_ARCH_NAME}, CUDA: ${CU_TAG}"

# Use GPU-specific venv
if [[ "$GPU_ARCH_NAME" == "cpu" ]]; then
  VENV_PATH="${VENV_ROOT}/cpu"
else
  VENV_PATH="${VENV_ROOT}/${GPU_ARCH_NAME}_${CU_TAG}"
fi

echo "[VENV] Using venv path: $VENV_PATH"

# Create/use venv
if [ ! -d "$VENV_PATH" ] || [ ! -f "$VENV_PATH/bin/python" ]; then
  echo "[VENV] Creating new venv for ${GPU_ARCH_NAME}"
  rm -rf "$VENV_PATH" 2>/dev/null || true
  mkdir -p "$VENV_PATH"
  
  for py_ver in python3.12 python3.11 python3.10 python3; do
    if command -v "$py_ver" &> /dev/null; then
      PYTHON_CMD="$py_ver"
      break
    fi
  done

  echo "[VENV] Using Python: $PYTHON_CMD"
  "$PYTHON_CMD" -m venv "$VENV_PATH" --upgrade-deps

  if [ ! -f "$VENV_PATH/bin/python" ]; then
    echo "[ERROR] Failed to create venv at $VENV_PATH"
    exit 1
  fi
else
  echo "[VENV] Using existing venv: $VENV_PATH"
fi

# Update legacy symlink
rm -f "$LEGACY_VENV" 2>/dev/null || true
ln -sfn "$VENV_PATH" "$LEGACY_VENV"

# Activate venv
source "$VENV_PATH/bin/activate"
PYBIN="$VENV_PATH/bin/python"
PIPBIN="$VENV_PATH/bin/pip"

"$PIPBIN" install --upgrade pip wheel setuptools &>/dev/null
echo "[INFO] Using Python: $($PYBIN --version)"

# PyTorch installation with correct version mapping for RTX 50xx
export TORCH_VER="2.8.0"
TORCH_LOCK_FILE="/mnt/netdrive/.torch_install_lock"

case "$CU_TAG" in
  cu128)
    TORCH_URL="https://download.pytorch.org/whl/cu128"
    # Use available TorchVision version for cu128
    TVISION_VER="0.23.0"
    ;;
  cu124)
    TORCH_URL="https://download.pytorch.org/whl/cu124" 
    TVISION_VER="0.23.1"
    ;;
  cu121)
    TORCH_URL="https://download.pytorch.org/whl/cu121"
    TVISION_VER="0.23.1"
    ;;
  cu118)
    TORCH_URL="https://download.pytorch.org/whl/cu118"
    TVISION_VER="0.23.1"
    ;;
  cpu)
    TORCH_URL="https://download.pytorch.org/whl/cpu"
    TVISION_VER="0.23.1"
    ;;
esac

echo "[TORCH] Target: ${TORCH_VER}+${CU_TAG}, TorchVision: ${TVISION_VER}+${CU_TAG}"

# Check for installation lock (ongoing installation)
if [ -f "$TORCH_LOCK_FILE" ]; then
  echo "[TORCH] Previous installation detected, waiting for completion..."
  for i in {1..60}; do
    if [ ! -f "$TORCH_LOCK_FILE" ]; then
      echo "[TORCH] Previous installation completed"
      break
    fi
    sleep 5
    echo "[TORCH] Waiting... ($((i*5))s)"
  done
  
  # Remove stale lock if timeout
  if [ -f "$TORCH_LOCK_FILE" ]; then
    echo "[TORCH] Removing stale installation lock"
    rm -f "$TORCH_LOCK_FILE"
  fi
fi

# Check if PyTorch is already installed correctly
TORCH_INSTALLED=false
if "$PYBIN" -c "import torch" &>/dev/null; then
  CURRENT_TORCH=$("$PYBIN" -c "import torch; print(torch.__version__)" 2>/dev/null || echo "")
  if [[ "$CURRENT_TORCH" == "${TORCH_VER}+${CU_TAG}" ]]; then
    echo "[TORCH] Already installed: $CURRENT_TORCH"
    TORCH_INSTALLED=true
  else
    echo "[TORCH] Version mismatch: found $CURRENT_TORCH, need ${TORCH_VER}+${CU_TAG}"
  fi
else
  echo "[TORCH] Not installed or import failed"
fi

# Install only if needed
if [[ "$TORCH_INSTALLED" == "false" ]]; then
  echo "[TORCH] Installing ${TORCH_VER}+${CU_TAG} with TorchVision ${TVISION_VER}+${CU_TAG}"
  
  # Create installation lock
  touch "$TORCH_LOCK_FILE"
  
  # Ensure cleanup on exit
  trap 'rm -f "$TORCH_LOCK_FILE"' EXIT INT TERM
  
  "$PIPBIN" uninstall -y torch torchvision torchaudio xformers &>/dev/null || true
  
  # Install with proper error handling
  "$PIPBIN" install --no-cache-dir --extra-index-url "$TORCH_URL" \
    torch=="${TORCH_VER}+${CU_TAG}" \
    torchvision=="${TVISION_VER}+${CU_TAG}" || {
    echo "[TORCH] Installation failed, removing lock"
    rm -f "$TORCH_LOCK_FILE"
    exit 1
  }
    
  "$PIPBIN" install --no-cache-dir filelock typing-extensions sympy networkx jinja2 fsspec numpy pillow &>/dev/null
  
  # Verify installation before removing lock
  if "$PYBIN" -c "import torch; print('PyTorch version:', torch.__version__)" &>/dev/null; then
    echo "[TORCH] Installation completed and verified"
    rm -f "$TORCH_LOCK_FILE"
  else
    echo "[TORCH] Installation failed verification"
    rm -f "$TORCH_LOCK_FILE"
    exit 1
  fi
fi

# Simple TorchVision test (non-blocking, avoid problematic NMS)
echo "[TORCH] Testing TorchVision compatibility..."
if "$PYBIN" -c "import torchvision.transforms" &>/dev/null; then
  echo "[TORCH] TorchVision transforms working"
else
  echo "[TORCH] TorchVision transforms not available"
fi

# xFormers installation - ใช้วิธีจาก GitHub (ง่ายกว่า)
if [ "$SKIP_XFORMERS" != "1" ]; then
  echo "[XFORMERS] Installing with GitHub method..."
  
  # ลบ xFormers เก่าก่อน
  "$PIPBIN" uninstall -y xformers &>/dev/null || true
  
  if [ -n "$XFORMERS_WHEEL_URL" ]; then
    # ใช้ wheel ที่กำหนด
    echo "[XFORMERS] Installing from wheel: $XFORMERS_WHEEL_URL"
    "$PIPBIN" install --no-deps "$XFORMERS_WHEEL_URL" &>/dev/null
  else
    # ใช้วิธีตาม GitHub xFormers (แนะนำให้ใช้ PyTorch 2.7.0)
    echo "[XFORMERS] Installing compatible version for PyTorch 2.8.0..."
    
    # ติดตั้ง xFormers ที่เข้ากันได้ ตาม GitHub recommendations
    case "$CU_TAG" in
      cu128)
        # สำหรับ CUDA 12.8
        "$PIPBIN" install --no-cache-dir \
          --extra-index-url "https://download.pytorch.org/whl/cu128" \
          "xformers" &>/dev/null || true
        ;;
      cu124)
        # สำหรับ CUDA 12.4  
        "$PIPBIN" install --no-cache-dir \
          --extra-index-url "https://download.pytorch.org/whl/cu124" \
          "xformers" &>/dev/null || true
        ;;
      cu121)
        # สำหรับ CUDA 12.1
        "$PIPBIN" install --no-cache-dir \
          --extra-index-url "https://download.pytorch.org/whl/cu121" \
          "xformers" &>/dev/null || true
        ;;
      *)
        # Fallback
        "$PIPBIN" install --no-cache-dir xformers &>/dev/null || true
        ;;
    esac
  fi
  
  # ตรวจสอบ import test อย่างง่าย
  if "$PYBIN" -c "import xformers" &>/dev/null; then
    echo "[XFORMERS] Successfully installed"
    
    # ตรวจสอบว่า C++/CUDA extensions โหลดได้หรือไม่
    if "$PYBIN" -c "import xformers.ops" &>/dev/null 2>&1; then
      echo "[XFORMERS] C++/CUDA extensions working"
    else
      echo "[XFORMERS] C++/CUDA extensions not working (will use PyTorch attention)"
      export XFORMERS_DISABLE_FLASH_ATTN=1
    fi
  else
    echo "[XFORMERS] Import failed, uninstalling"
    "$PIPBIN" uninstall -y xformers &>/dev/null || true
  fi
fi

# Get ComfyUI
if [ ! -d "$COMFYUI_ROOT" ] || [ -z "$(ls -A "$COMFYUI_ROOT" 2>/dev/null)" ]; then
  echo "[COMFYUI] Cloning to network volume..."
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_ROOT" &>/dev/null
fi

# Dependencies installation
echo "[DEPS] Installing requirements..."
cat > /tmp/constraints.txt <<EOF
torch==${TORCH_VER}+${CU_TAG}
torchvision==${TVISION_VER}+${CU_TAG}
EOF

# Install ComfyUI requirements
if [ -f "${COMFYUI_ROOT}/requirements.txt" ]; then
  "$PIPBIN" install --no-cache-dir --quiet --constraint /tmp/constraints.txt \
    -r "${COMFYUI_ROOT}/requirements.txt" &>/dev/null || true
fi

# Install enhanced requirements
if [ -f "/requirements.txt" ]; then
  "$PIPBIN" install --no-cache-dir --quiet --constraint /tmp/constraints.txt \
    -r "/requirements.txt" &>/dev/null || true
fi

rm -f /tmp/constraints.txt

# Jupyter setup
if [ "$ENABLE_JUPYTER" = "true" ]; then
  echo "[JUPYTER] Setting up on :$JUPYTER_PORT"
  "$PIPBIN" install --no-cache-dir --quiet jupyter jupyterlab &>/dev/null
  mkdir -p "$JUPYTER_CONFIG_DIR"
  
  nohup "$PYBIN" -m jupyter lab \
    --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    --ServerApp.token='' --ServerApp.password='' \
    --ServerApp.allow_origin='*' --ServerApp.allow_remote_access=True \
    --ServerApp.port_retries=0 --ServerApp.root_dir=/mnt/netdrive \
    > /mnt/netdrive/jupyter.log 2>&1 &

  sleep 5
  if curl -sSf http://127.0.0.1:"$JUPYTER_PORT" &>/dev/null; then 
    echo "[JUPYTER] Running on :$JUPYTER_PORT"
  fi
fi

echo "[INFO] Python: $($PYBIN --version)"

# Setup custom nodes and models
echo "[SETUP] Starting parallel setup..."

"$PYBIN" /setup_custom_nodes.py > /mnt/netdrive/comfyui/setup_custom_nodes.log 2>&1 &
CUSTOM_NODES_PID=$!

"$PYBIN" /download_models.py > /mnt/netdrive/comfyui/download_models.log 2>&1 &
DOWNLOAD_MODELS_PID=$!

# Monitor setup
monitor_start_time=$(date +%s)
while kill -0 $CUSTOM_NODES_PID 2>/dev/null || kill -0 $DOWNLOAD_MODELS_PID 2>/dev/null; do
    current_time=$(date +%s)
    elapsed=$((current_time - monitor_start_time))
    
    if (( elapsed % 60 == 0 )) && (( elapsed > 0 )); then
        echo "[SETUP] Progress: ${elapsed}s elapsed"
    fi
    
    sleep 10
done

wait $CUSTOM_NODES_PID $DOWNLOAD_MODELS_PID 2>/dev/null || true
echo "[SETUP] Parallel setup completed"

# Cleanup
rm -rf /mnt/netdrive/tmp/* 2>/dev/null || true

# GPU info
if command -v nvidia-smi &> /dev/null; then
  GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | head -1)
  echo "[GPU] $GPU_INFO"
fi

# Simple compatibility check (non-blocking, informational only)
echo "[PRESTART] Checking dependencies..."
if "$PYBIN" -c "import torch" &>/dev/null; then
  echo "[PRESTART] PyTorch import: OK"
else
  echo "[PRESTART] PyTorch import: FAILED"
fi

if "$PYBIN" -c "import torchvision" &>/dev/null; then
  echo "[PRESTART] TorchVision import: OK"
else
  echo "[PRESTART] TorchVision import: FAILED"
fi

# Start ComfyUI
cd "$COMFYUI_ROOT"

ARGS=(
  --listen "$COMFYUI_HOST"
  --port "$COMFYUI_PORT"
  --preview-method auto
)

if [ $# -gt 0 ]; then
  ARGS+=("$@")
fi

if ! "$PYBIN" -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
  echo "[COMFYUI] Adding --cpu flag"
  ARGS+=(--cpu)
fi

echo "[COMFYUI] Starting on ${COMFYUI_HOST}:${COMFYUI_PORT}"
"$PYBIN" main.py "${ARGS[@]}" 2>&1 | tee /mnt/netdrive/comfyui/main.log &

# Health check
echo "[HEALTHCHECK] Waiting for ComfyUI..."
for i in {1..10}; do
    if curl -s http://${COMFYUI_HOST}:${COMFYUI_PORT} &>/dev/null; then
        echo "[HEALTHCHECK] ComfyUI ready after $((i*15)) seconds"
        break
    fi
    sleep 15
done

echo "[READY] Pod ready!"
sleep infinity