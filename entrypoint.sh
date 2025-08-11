#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
: "${COMFYUI_ROOT:=/mnt/netdrive/comfyui}"
: "${VENV_ROOT:=/mnt/netdrive/python_envs}"
: "${PIP_CACHE_DIR:=/mnt/netdrive/pip_cache}"
: "${TMPDIR:=/mnt/netdrive/tmp}"
: "${LEGACY_VENV:=/mnt/netdrive/python_env}"
: "${JUPYTER_CONFIG_DIR:=/mnt/netdrive/config/jupyter}"

# Service network defaults (overridable by env)
: "${COMFYUI_HOST:=0.0.0.0}"
: "${COMFYUI_PORT:=8188}"
: "${JUPYTER_PORT:=8888}"

# Simplified xFormers configuration (smart defaults)
: "${SKIP_XFORMERS:=0}"  # Default to enable xFormers
: "${XFORMERS_WHEEL_URL:=}"

# Hopper/Ada compatibility settings (auto-detect)
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
export CUDA_MODULE_LOADING=LAZY

# Check GPU architecture and set compatibility flags automatically
GPU_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d '.' || echo "0")
if [[ "$GPU_ARCH" =~ ^[0-9]+$ ]] && [[ "$GPU_ARCH" -ge "90" ]]; then
  echo "[INFO] Hopper/Ada GPU detected, setting compatibility flags"
  export XFORMERS_DISABLE_FLASH_ATTN=1
fi

# --- Normalize ENV values ---
: "${ENABLE_JUPYTER:=true}"  # Default to true for convenience
case "${ENABLE_JUPYTER,,}" in
  false|0|no|disable) ENABLE_JUPYTER=false ;;
  *)                  ENABLE_JUPYTER=true ;;
esac

case "${SKIP_XFORMERS,,}" in
  1|true|yes|skip) SKIP_XFORMERS=true ;;
  *)               SKIP_XFORMERS=false ;;
esac

# --- Derived paths ---
export COMFYUI_DIR="$COMFYUI_ROOT"
export COMFYUI_CUSTOM_NODES="$COMFYUI_DIR/custom_nodes"
export COMFYUI_MODELS="$COMFYUI_DIR/models"

# --- Ensure network volume is mounted ---
if command -v mountpoint >/dev/null 2>&1; then
  if ! mountpoint -q /mnt/netdrive; then
    echo "[BOOT] Waiting for /mnt/netdrive to be mounted..."
    for i in {1..60}; do mountpoint -q /mnt/netdrive && break; sleep 1; done
  fi
else
  for i in {1..60}; do grep -qs " /mnt/netdrive " /proc/mounts && break; sleep 1; done
fi
if ! grep -qs " /mnt/netdrive " /proc/mounts; then
  echo "[ERROR] /mnt/netdrive is not mounted. Abort to avoid installing into container."
  exit 1
fi

# --- Create required dirs ---
mkdir -p "$PIP_CACHE_DIR" "$TMPDIR" "$VENV_ROOT" "$COMFYUI_ROOT"

# Setup pip environment
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_CONFIG_FILE=/dev/null
export PYTHONNOUSERSITE=1
export PIP_USER=0
export PIP_PREFER_BINARY=1

echo "[BOOT] Host driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 || echo 'unknown')"

# --- Auto-detect CUDA version ---
GPU_CC_RAW="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n1 || true)"
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

echo "[INFO] GPU Architecture: ${GPU_ARCH_NAME}, CUDA Tag: ${CU_TAG}"

# Use GPU architecture specific venv
if [[ "$GPU_ARCH_NAME" == "cpu" ]]; then
  VENV_PATH="${VENV_ROOT}/cpu"
else
  VENV_PATH="${VENV_ROOT}/${GPU_ARCH_NAME}_${CU_TAG}"
fi
echo "[VENV] Using venv path: $VENV_PATH"

# Create venv if needed
if [ ! -d "$VENV_PATH" ] || [ ! -f "$VENV_PATH/bin/python" ]; then
  echo "[VENV] Creating new venv at $VENV_PATH for ${GPU_ARCH_NAME}"
  rm -rf "$VENV_PATH" 2>/dev/null || true
  mkdir -p "$VENV_PATH"
  
  # Find best available Python version
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
fi

# Update legacy symlink
if [ -L "$LEGACY_VENV" ]; then
  rm -f "$LEGACY_VENV"
fi
ln -sfn "$VENV_PATH" "$LEGACY_VENV"

# Activate venv
source "$VENV_PATH/bin/activate"
PYBIN="$VENV_PATH/bin/python"
PIPBIN="$VENV_PATH/bin/pip"

"$PYBIN" -m pip install --upgrade pip wheel setuptools
echo "[INFO] Using Python: $($PYBIN --version)"

# ---- PyTorch Installation ----
export TORCH_VER="2.8.0"

# Set PyTorch index URLs based on detected CUDA
case "$CU_TAG" in
  cu128)
    TORCH_URL="https://download.pytorch.org/whl/cu128"
    TORCH_SUFFIX="cu128"
    TVISION_VER="0.23.0"
    ;;
  cu124)
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
  echo "[TORCH] Installing PyTorch ${TORCH_VER}+${CU_TAG}"
  
  # Clean install
  "$PYBIN" -m pip uninstall -y torch torchvision torchaudio xformers 2>/dev/null || true
  
  "$PYBIN" -m pip install --no-cache-dir --force-reinstall \
    --extra-index-url "$TORCH_URL" \
    torch=="${TORCH_VER}+${CU_TAG}" \
    torchvision=="${TVISION_VER}+${CU_TAG}"
    
  # Install core dependencies
  "$PYBIN" -m pip install --no-cache-dir \
    filelock typing-extensions sympy networkx jinja2 fsspec numpy pillow
else
  echo "[TORCH] Correct version already installed: $CURRENT_TORCH"
fi

# --- Smart xFormers Installation ---
install_xformers() {
  if [ "$SKIP_XFORMERS" = "true" ]; then
    echo "[XFORMERS] Skipped (SKIP_XFORMERS=true)"
    export XFORMERS_DISABLE_FLASH_ATTN=1
    return 0
  fi

  if [ "$CU_TAG" = "cpu" ]; then
    echo "[XFORMERS] Skipped (CPU mode)"
    return 0
  fi

  echo "[XFORMERS] Installing with compatibility checks..."
  
  # Create constraints to prevent torch version conflicts
  cat > /tmp/xformers_constraints.txt <<EOF
torch==${TORCH_VER}+${CU_TAG}
torchvision==${TVISION_VER}+${CU_TAG}
EOF

  # Try specific wheel URL first if provided
  if [ -n "$XFORMERS_WHEEL_URL" ]; then
    echo "[XFORMERS] Installing from wheel: $XFORMERS_WHEEL_URL"
    if "$PIPBIN" install --no-cache-dir --no-deps "$XFORMERS_WHEEL_URL"; then
      echo "[XFORMERS] Wheel installation successful"
    else
      echo "[XFORMERS] Wheel installation failed, trying alternatives..."
    fi
  else
    # Try PyTorch index installation
    echo "[XFORMERS] Installing from PyTorch index"
    "$PIPBIN" install --no-cache-dir \
      --constraint /tmp/xformers_constraints.txt \
      --extra-index-url "$TORCH_URL" \
      "xformers>=0.0.26" || echo "[XFORMERS] Installation failed, will use PyTorch attention"
  fi

  # Verify installation and torch version
  TORCH_AFTER=$("$PYBIN" -c "import torch; print(torch.__version__)" 2>/dev/null || echo "unknown")
  if [[ "$TORCH_AFTER" != "${TORCH_VER}+${CU_TAG}" ]]; then
    echo "[XFORMERS] WARNING: Torch version changed, reinstalling correct version"
    "$PIPBIN" install --no-cache-dir --force-reinstall --no-deps \
      --extra-index-url "$TORCH_URL" \
      torch=="${TORCH_VER}+${CU_TAG}" \
      torchvision=="${TVISION_VER}+${CU_TAG}"
  fi

  # Test xformers compatibility
  if ! "$PYBIN" -c "import xformers; import torch; print('[XFORMERS] Successfully loaded')" 2>/dev/null; then
    echo "[XFORMERS] Compatibility test failed, uninstalling..."
    "$PYBIN" -m pip uninstall -y xformers || true
    export XFORMERS_DISABLE_FLASH_ATTN=1
  else
    echo "[XFORMERS] Installation successful and compatible"
  fi

  rm -f /tmp/xformers_constraints.txt
}

# Install xFormers
install_xformers

# Get ComfyUI
if [ ! -d "$COMFYUI_DIR" ] || [ -z "$(ls -A "$COMFYUI_DIR" 2>/dev/null)" ]; then
  echo "[COMFYUI] Cloning ComfyUI..."
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
fi

# --- Install ComfyUI requirements ---
REQ="${COMFYUI_DIR}/requirements.txt"
if [ -f "$REQ" ]; then
  echo "[DEPS] Installing ComfyUI requirements"
  cat > /tmp/constraints.txt <<EOF
torch==${TORCH_VER}+${CU_TAG}
torchvision==${TVISION_VER}+${CU_TAG}
EOF
  
  # Install requirements while protecting torch version
  "$PYBIN" -m pip install --no-cache-dir \
    --constraint /tmp/constraints.txt \
    -r "$REQ" || echo "[DEPS] Some dependencies failed, continuing..."
  
  rm -f /tmp/constraints.txt
fi

# Install our enhanced requirements
ENHANCED_REQ="/requirements.txt"
if [ -f "$ENHANCED_REQ" ]; then
  echo "[DEPS] Installing enhanced requirements"
  cat > /tmp/constraints.txt <<EOF
torch==${TORCH_VER}+${CU_TAG}
torchvision==${TVISION_VER}+${CU_TAG}
EOF
  
  "$PYBIN" -m pip install --no-cache-dir \
    --constraint /tmp/constraints.txt \
    -r "$ENHANCED_REQ" || echo "[DEPS] Some enhanced dependencies failed, continuing..."
  
  rm -f /tmp/constraints.txt
fi

# --- Jupyter setup ---
if [ "${ENABLE_JUPYTER}" = "true" ]; then
  echo "[JUPYTER] Enabling JupyterLab on :$JUPYTER_PORT"
  "$PYBIN" -m pip install --no-cache-dir jupyter jupyterlab
  mkdir -p "$JUPYTER_CONFIG_DIR"
  
  nohup "$PYBIN" -m jupyter lab \
    --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    --ServerApp.token='' --ServerApp.password='' \
    --ServerApp.allow_origin='*' --ServerApp.allow_remote_access=True \
    --ServerApp.port_retries=0 --ServerApp.root_dir=/mnt/netdrive \
    > /mnt/netdrive/jupyter.log 2>&1 &

  # Wait for Jupyter to start
  for i in {1..12}; do
    sleep 5
    if curl -sSf http://127.0.0.1:"$JUPYTER_PORT" >/dev/null 2>&1; then 
      echo "[JUPYTER] Up and running"
      break
    fi
  done
fi

echo "[INFO] Python: $(which python) ($(python --version))"

# --- Custom Nodes & Models Setup ---
echo "[SETUP] Starting parallel setup..."
echo "[DEBUG] Available resources:"
df -h /mnt/netdrive | head -2
free -h | head -2

"$PYBIN" /setup_custom_nodes.py > /mnt/netdrive/comfyui/setup_custom_nodes.log 2>&1 &
CUSTOM_NODES_PID=$!

"$PYBIN" /download_models.py > /mnt/netdrive/comfyui/download_models.log 2>&1 &
DOWNLOAD_MODELS_PID=$!

# Monitor setup progress
monitor_start_time=$(date +%s)
while kill -0 $CUSTOM_NODES_PID 2>/dev/null || kill -0 $DOWNLOAD_MODELS_PID 2>/dev/null; do
    current_time=$(date +%s)
    elapsed=$((current_time - monitor_start_time))
    
    if (( elapsed % 30 == 0 )); then
        echo "[SETUP] Still running... ${elapsed}s elapsed"
    fi
    
    sleep 5
done

wait $CUSTOM_NODES_PID $DOWNLOAD_MODELS_PID 2>/dev/null || true
echo "[SETUP] Parallel setup completed"

# Cleanup
echo "[CLEANUP] Cleaning up..."
rm -rf /mnt/netdrive/tmp/* 2>/dev/null || true

# GPU info
if command -v nvidia-smi &> /dev/null; then
  echo "[GPU] Available GPUs:"
  nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits | head -3
fi

# --- Start ComfyUI ---
cd "$COMFYUI_DIR"

ARGS=(
  --listen "$COMFYUI_HOST"
  --port "$COMFYUI_PORT"
  --preview-method auto
)

if [ $# -gt 0 ]; then
  ARGS+=("$@")
fi

# Check CUDA availability
if ! "$PYBIN" -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
  echo "[COMFYUI] CUDA not available, adding --cpu flag"
  ARGS+=(--cpu)
fi

echo "[COMFYUI] Starting on ${COMFYUI_HOST}:${COMFYUI_PORT}"
"$PYBIN" main.py "${ARGS[@]}" 2>&1 | tee /mnt/netdrive/comfyui/main.log &

# Health check
echo "[HEALTHCHECK] Waiting for ComfyUI..."
for i in {1..10}; do
    if curl -s http://${COMFYUI_HOST}:${COMFYUI_PORT} > /dev/null 2>&1; then
        echo "[HEALTHCHECK] ✅ ComfyUI is ready after $((i*30)) seconds"
        break
    fi
    echo "[HEALTHCHECK] Waiting... $((i*30))s"
    sleep 30
done

echo "[READY] Pod is ready!"
sleep infinity