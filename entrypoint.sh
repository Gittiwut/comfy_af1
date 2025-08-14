#!/usr/bin/env bash
# Universal ComfyUI Entrypoint - Multi-GPU Architecture Support
# Supports: RTX 4090 (Ada) → RTX 5090 (Blackwell) → H100 (Hopper) → B200 (Blackwell)
set -euo pipefail

# Configuration
: "${COMFYUI_ROOT:=/mnt/netdrive/comfyui}"
: "${VENV_ROOT:=/mnt/netdrive/python_envs}"
: "${PIP_CACHE_DIR:=/mnt/netdrive/pip_cache}"
: "${COMPUTE_CACHE_DIR:=/mnt/netdrive/.nv/ComputeCache}"
: "${TMPDIR:=/mnt/netdrive/tmp}"
: "${JUPYTER_CONFIG_DIR:=/mnt/netdrive/config/jupyter}"
: "${PYTHON_VERSION:=3.11}"

# Service defaults
: "${COMFYUI_HOST:=0.0.0.0}"
: "${COMFYUI_PORT:=8188}"
: "${JUPYTER_PORT:=8888}"
: "${ENABLE_JUPYTER:=true}"
: "${SKIP_XFORMERS:=0}"

# Universal environment setup
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONNOUSERSITE=1
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
export CUDA_MODULE_LOADING=LAZY
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True,max_split_size_mb:128"

# Mount verification
if ! grep -qs " /mnt/netdrive " /proc/mounts; then
  echo "[ERROR] /mnt/netdrive not mounted"
  exit 1
fi

# Ensure all directories exist
mkdir -p "$PIP_CACHE_DIR" "$TMPDIR" "$VENV_ROOT" "$COMFYUI_ROOT" "$JUPYTER_CONFIG_DIR" "$COMPUTE_CACHE_DIR"

echo "🚀 [STARTUP] Universal ComfyUI Multi-GPU Detection Starting..."

# Enhanced GPU Detection with Architecture Mapping
if ! command -v nvidia-smi &> /dev/null; then
    echo "[ERROR] nvidia-smi not found - NVIDIA drivers not available"
    exit 1
fi

# Get comprehensive GPU information
GPU_INFO=$(nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total --format=csv,noheader 2>/dev/null | head -n1 || echo "")
if [[ -z "$GPU_INFO" ]]; then
    echo "[ERROR] Failed to detect GPU information"
    exit 1
fi

# Parse GPU information
IFS=',' read -r GPU_NAME GPU_CC_RAW DRIVER_VERSION GPU_MEMORY <<< "$GPU_INFO"
GPU_NAME=$(echo "$GPU_NAME" | xargs)
GPU_CC_RAW=$(echo "$GPU_CC_RAW" | xargs)
DRIVER_VERSION=$(echo "$DRIVER_VERSION" | xargs)
GPU_MEMORY=$(echo "$GPU_MEMORY" | xargs)

echo "🎯 [GPU] Detected: $GPU_NAME"
echo "📊 [GPU] Compute Capability: $GPU_CC_RAW"
echo "🔧 [GPU] Driver Version: $DRIVER_VERSION"
echo "💾 [GPU] Memory: $GPU_MEMORY MB"

# Parse compute capability
GPU_CC_MAJ="${GPU_CC_RAW%%.*}"
GPU_CC_MIN="${GPU_CC_RAW##*.}"
GPU_CC_NUM=$((GPU_CC_MAJ * 10 + GPU_CC_MIN))

# Architecture Detection and Mapping
ARCH_TAG=""
CU_TAG=""
CONSTRAINTS_FILE=""
TORCH_CUDA_ARCH_LIST=""

echo "🔍 [ARCH] Detecting GPU architecture..."

if (( GPU_CC_NUM >= 100 )); then
    # Blackwell (RTX 5090, B200) - CC 10.0+
    ARCH_TAG="blackwell"
    CU_TAG="cu124"
    CONSTRAINTS_FILE="constraints_blackwell.txt"
    TORCH_CUDA_ARCH_LIST="8.9;9.0;10.0;10.0+PTX"
    echo "⚡ [ARCH] Blackwell detected (RTX 5090/B200 class)"
elif (( GPU_CC_NUM >= 90 )); then
    # Hopper (H100) - CC 9.0
    ARCH_TAG="hopper"
    CU_TAG="cu121"
    CONSTRAINTS_FILE="constraints_hopper.txt"
    TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;9.0+PTX"
    echo "🏢 [ARCH] Hopper detected (H100 class)"
elif (( GPU_CC_NUM >= 89 )); then
    # Ada Lovelace (RTX 4090) - CC 8.9
    ARCH_TAG="ada"
    CU_TAG="cu121"
    CONSTRAINTS_FILE="constraints_ada.txt"
    TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;8.9+PTX"
    echo "🎮 [ARCH] Ada Lovelace detected (RTX 4090 class)"
elif (( GPU_CC_NUM >= 86 )); then
    # Ampere (RTX 3090, A100) - CC 8.6
    ARCH_TAG="ada"  # Use Ada constraints as fallback
    CU_TAG="cu121"
    CONSTRAINTS_FILE="constraints_ada.txt"
    TORCH_CUDA_ARCH_LIST="8.0;8.6;8.6+PTX"
    echo "⚡ [ARCH] Ampere detected (RTX 3090/A100 class) - using Ada fallback"
else
    echo "[ERROR] Unsupported GPU architecture (CC: $GPU_CC_RAW)"
    echo "[INFO] Minimum requirement: Compute Capability 8.6+"
    exit 1
fi

# Set architecture-specific environment variables
export TORCH_CUDA_ARCH_LIST="$TORCH_CUDA_ARCH_LIST"
export CUDA_ARCH_TAG="$ARCH_TAG"

echo "🏗️  [ARCH] Architecture: $ARCH_TAG"
echo "🏗️  [ARCH] CUDA Tag: $CU_TAG"
echo "🏗️  [ARCH] Constraints: $CONSTRAINTS_FILE"
echo "🏗️  [ARCH] Torch Arch List: $TORCH_CUDA_ARCH_LIST"

# Virtual Environment Setup
VENV_PATH="${VENV_ROOT}/${ARCH_TAG}"
echo "📦 [VENV] Using architecture-specific venv: $VENV_PATH"

# Python detection
PYTHON_CMD=""
for py_ver in python${PYTHON_VERSION} python3.11 python3.10 python3.12 python3; do
  if command -v "$py_ver" &> /dev/null; then
    PYTHON_CMD="$py_ver"
    echo "🐍 [PYTHON] Found: $PYTHON_CMD ($($py_ver --version))"
    break
  fi
done

if [[ -z "$PYTHON_CMD" ]]; then
  echo "[ERROR] No suitable Python found"
  exit 1
fi

# Create or verify virtual environment
if [ ! -d "$VENV_PATH" ] || [ ! -f "$VENV_PATH/bin/python" ]; then
  echo "🏗️  [VENV] Creating new venv for $ARCH_TAG with $PYTHON_CMD"
  rm -rf "$VENV_PATH" 2>/dev/null || true
  mkdir -p "$VENV_PATH"
  
  "$PYTHON_CMD" -m venv "$VENV_PATH" --upgrade-deps
  
  if [ ! -f "$VENV_PATH/bin/python" ]; then
    echo "[ERROR] Failed to create venv at $VENV_PATH"
    exit 1
  fi
else
  echo "♻️  [VENV] Using existing venv: $VENV_PATH"
fi

# Environment setup
export VENV_PATH="$VENV_PATH"
export PYBIN="$VENV_PATH/bin/python"
export PIPBIN="$VENV_PATH/bin/pip"

# Dynamic Python version detection for PYTHONPATH
PYTHON_FULL_VER=$("$PYBIN" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
export PYTHONPATH="$VENV_PATH/lib/python${PYTHON_FULL_VER}/site-packages:${PYTHONPATH:-}"
export PATH="$VENV_PATH/bin:$PATH"

# Activate virtual environment
source "$VENV_PATH/bin/activate"

echo "✅ [VENV] Active Python: $("$PYBIN" -c "import sys; print(sys.executable)")"
echo "✅ [VENV] Python version: $("$PYBIN" --version)"

# Configure pip
"$PIPBIN" config set global.cache-dir "$PIP_CACHE_DIR" 2>/dev/null || true
"$PIPBIN" install --upgrade pip wheel setuptools &>/dev/null

# Enhanced Package Installation with Architecture-Specific Constraints
CONSTRAINTS_PATH="/constraints/$CONSTRAINTS_FILE"

if [ ! -f "$CONSTRAINTS_PATH" ]; then
  echo "[ERROR] Constraints file not found: $CONSTRAINTS_PATH"
  echo "[INFO] Available constraints:"
  ls -la /constraints/ 2>/dev/null || echo "No constraints directory found"
  exit 1
fi

echo "📋 [DEPS] Using constraints: $CONSTRAINTS_FILE"

# Check if packages are already installed
PACKAGES_INSTALLED=false
TORCH_LOCK_FILE="/mnt/netdrive/.torch_install_lock_${ARCH_TAG}"

# Quick PyTorch version check
if "$PYBIN" -c "import torch" &>/dev/null; then
  CURRENT_TORCH=$("$PYBIN" -c "import torch; print(torch.__version__)" 2>/dev/null || echo "")
  EXPECTED_TORCH=$(grep "^torch==" "$CONSTRAINTS_PATH" | cut -d'=' -f3 | cut -d'+' -f1 || echo "")
  
  if [[ "$CURRENT_TORCH" =~ $EXPECTED_TORCH ]]; then
    echo "✅ [TORCH] Already installed: $CURRENT_TORCH"
    PACKAGES_INSTALLED=true
  else
    echo "🔄 [TORCH] Version mismatch: found $CURRENT_TORCH, constraints specify $EXPECTED_TORCH"
    echo "🧹 [TORCH] Cleaning up for reinstallation..."
    "$PIPBIN" uninstall -y torch torchvision torchaudio xformers triton &>/dev/null || true
  fi
else
  echo "📦 [TORCH] Not installed or import failed"
fi

# Install packages if needed
if [[ "$PACKAGES_INSTALLED" == "false" ]]; then
  # Handle concurrent installations
  if [ -f "$TORCH_LOCK_FILE" ]; then
    echo "⏳ [TORCH] Another installation in progress, waiting..."
    for i in {1..60}; do
      if [ ! -f "$TORCH_LOCK_FILE" ]; then
        echo "✅ [TORCH] Previous installation completed"
        break
      fi
      sleep 5
      echo "⏳ [TORCH] Waiting... $((i*5))s"
    done
    
    if [ -f "$TORCH_LOCK_FILE" ]; then
      echo "🧹 [TORCH] Removing stale lock"
      rm -f "$TORCH_LOCK_FILE"
    fi
  fi
  
  echo "📦 [DEPS] Installing packages for $ARCH_TAG architecture..."
  
  # Create lock file
  touch "$TORCH_LOCK_FILE"
  trap 'rm -f "$TORCH_LOCK_FILE"' EXIT INT TERM
  
  # Install with architecture-specific constraints
  # First install core requirements, then constraints
  if "$PIPBIN" install --no-cache-dir -r "/requirements.txt"; then
    echo "✅ [DEPS] Core requirements installed"
    
    # Then install architecture-specific packages
    if "$PIPBIN" install --no-cache-dir --constraint "$CONSTRAINTS_PATH" \
      torch torchvision torchaudio xformers triton; then
      
      echo "✅ [DEPS] Architecture-specific packages installed"
      rm -f "$TORCH_LOCK_FILE"
    else
      echo "[ERROR] Architecture-specific package installation failed"
      rm -f "$TORCH_LOCK_FILE"
      exit 1
    fi
  else
    echo "[ERROR] Core requirements installation failed"
    rm -f "$TORCH_LOCK_FILE"
    exit 1
  fi
fi

# Comprehensive verification
echo "🔍 [VERIFY] Running comprehensive verification..."

# Test PyTorch with CUDA
VERIFY_SUCCESS=true
if python3 -c "
import sys
sys.path.insert(0, '$VENV_PATH/lib/python${PYTHON_FULL_VER}/site-packages')
import torch
print(f'✅ PyTorch {torch.__version__} loaded')
print(f'✅ CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'✅ GPU: {torch.cuda.get_device_name()}')
    print(f'✅ Compute Capability: {torch.cuda.get_device_capability()}')
    print(f'✅ Memory: {torch.cuda.get_device_properties(0).total_memory // 1024**3}GB')
    
    # Test basic operations
    x = torch.randn(1000, 1000, device='cuda')
    y = torch.mm(x, x)
    print(f'✅ Basic CUDA operations: PASSED')
else:
    print('⚠️  CUDA not available - will run in CPU mode')
" 2>/dev/null; then
  echo "✅ [VERIFY] PyTorch verification: PASSED"
else
  echo "❌ [VERIFY] PyTorch verification: FAILED"
  VERIFY_SUCCESS=false
fi

# Test xFormers if installed
if "$PYBIN" -c "import xformers" &>/dev/null; then
  if "$PYBIN" -c "import xformers.ops" &>/dev/null 2>&1; then
    echo "✅ [VERIFY] xFormers: PASSED with CUDA extensions"
  else
    echo "⚠️  [VERIFY] xFormers: PASSED but using PyTorch fallback"
    export XFORMERS_DISABLE_FLASH_ATTN=1
  fi
else
  echo "ℹ️  [VERIFY] xFormers: Not installed"
fi

# Test Triton if installed
if "$PYBIN" -c "import triton" &>/dev/null; then
  echo "✅ [VERIFY] Triton: PASSED"
else
  echo "ℹ️  [VERIFY] Triton: Not installed"
fi

if [[ "$VERIFY_SUCCESS" == "false" ]]; then
  echo "[ERROR] Critical verification failed"
  exit 1
fi

# ComfyUI Setup
if [ ! -d "$COMFYUI_ROOT" ] || [ -z "$(ls -A "$COMFYUI_ROOT" 2>/dev/null)" ]; then
  echo "📥 [COMFYUI] Cloning repository..."
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_ROOT" &>/dev/null
fi

# Install ComfyUI requirements
if [ -f "${COMFYUI_ROOT}/requirements.txt" ]; then
  echo "📦 [COMFYUI] Installing ComfyUI requirements..."
  "$PIPBIN" install --no-cache-dir -r "${COMFYUI_ROOT}/requirements.txt" || true
fi

# Jupyter setup
if [ "$ENABLE_JUPYTER" = "true" ]; then
  echo "📓 [JUPYTER] Setting up on :$JUPYTER_PORT"
  "$PIPBIN" install --no-cache-dir --quiet jupyter jupyterlab &>/dev/null
  mkdir -p "$JUPYTER_CONFIG_DIR"
  
  nohup "$PYBIN" -m jupyter lab \
    --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    --ServerApp.token='' --ServerApp.password='' \
    --ServerApp.allow_origin='*' --ServerApp.allow_remote_access=True \
    --ServerApp.port_retries=0 --ServerApp.root_dir=/mnt/netdrive \
    > /mnt/netdrive/jupyter.log 2>&1 &

  sleep 3
  if curl -sSf http://127.0.0.1:"$JUPYTER_PORT" &>/dev/null; then 
    echo "✅ [JUPYTER] Running on :$JUPYTER_PORT"
  else
    echo "⏳ [JUPYTER] May need additional startup time"
  fi
fi

# Parallel setup - NO TIMEOUT for slow connections
echo "🏗️  [SETUP] Starting parallel setup..."
echo "[INFO] No timeout set - setup will complete regardless of time"

"$PYBIN" /setup_custom_nodes.py > /mnt/netdrive/comfyui/setup_custom_nodes.log 2>&1 &
CUSTOM_NODES_PID=$!

"$PYBIN" /download_models.py > /mnt/netdrive/comfyui/download_models.log 2>&1 &
DOWNLOAD_MODELS_PID=$!

# Monitor setup with progress feedback - NO TIMEOUT
monitor_start_time=$(date +%s)
echo "[INFO] Monitoring setup progress (no timeout)..."
while kill -0 $CUSTOM_NODES_PID 2>/dev/null || kill -0 $DOWNLOAD_MODELS_PID 2>/dev/null; do
    current_time=$(date +%s)
    elapsed=$((current_time - monitor_start_time))
    
    # Show progress every 60 seconds
    if (( elapsed % 60 == 0 )) && (( elapsed > 0 )); then
        echo "⏳ [SETUP] Progress: ${elapsed}s elapsed - still running..."
        # Show recent activity from logs
        if [ -f /mnt/netdrive/comfyui/setup_custom_nodes.log ]; then
            echo "   Custom nodes: $(tail -n 1 /mnt/netdrive/comfyui/setup_custom_nodes.log 2>/dev/null | head -c 80)..."
        fi
        if [ -f /mnt/netdrive/comfyui/download_models.log ]; then
            echo "   Models: $(tail -n 1 /mnt/netdrive/comfyui/download_models.log 2>/dev/null | head -c 80)..."
        fi
    fi
    
    sleep 10  # Check every 10 seconds
done

wait $CUSTOM_NODES_PID $DOWNLOAD_MODELS_PID 2>/dev/null || true
echo "✅ [SETUP] Parallel setup completed"

# Cleanup
rm -rf /mnt/netdrive/tmp/* 2>/dev/null || true

# GPU summary
echo "🏁 [SUMMARY] GPU Configuration:"
echo "  🎯 Architecture: $ARCH_TAG ($GPU_NAME)"
echo "  🔧 Compute Capability: $GPU_CC_RAW"
echo "  💾 Memory: $GPU_MEMORY MB" 
echo "  📦 Virtual Environment: $VENV_PATH"
echo "  🧬 PyTorch CUDA Arch List: $TORCH_CUDA_ARCH_LIST"

# Start ComfyUI
cd "$COMFYUI_ROOT"

ARGS=(
  --listen "$COMFYUI_HOST"
  --port "$COMFYUI_PORT"
  --preview-method auto
  --verbose
)

# Add user arguments
if [ $# -gt 0 ]; then
  ARGS+=("$@")
fi

# CPU fallback check
if ! "$PYBIN" -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
  echo "⚠️  [COMFYUI] CUDA not available, adding --cpu flag"
  ARGS+=(--cpu)
fi

echo "🚀 [COMFYUI] Starting on ${COMFYUI_HOST}:${COMFYUI_PORT}"
echo "📋 [COMFYUI] Arguments: ${ARGS[*]}"
echo "🎯 [COMFYUI] Optimized for: $ARCH_TAG architecture"

# Start ComfyUI with enhanced logging
"$PYBIN" main.py "${ARGS[@]}" 2>&1 | tee /mnt/netdrive/comfyui/main.log &
COMFYUI_PID=$!

# Health check
echo "🔍 [HEALTH] Waiting for ComfyUI startup..."
for i in {1..20}; do
    if curl -s http://${COMFYUI_HOST}:${COMFYUI_PORT} &>/dev/null; then
        echo "✅ [HEALTH] ComfyUI ready after $((i*3)) seconds"
        break
    elif [ $i -eq 20 ]; then
        echo "⚠️  [HEALTH] ComfyUI startup timeout - check logs"
        tail -n 20 /mnt/netdrive/comfyui/main.log 2>/dev/null || true
    fi
    sleep 3
done

echo ""
echo "🎉 ===== UNIVERSAL COMFYUI READY ====="
echo "🎯 Architecture: $ARCH_TAG ($GPU_NAME)"
echo "🌐 ComfyUI: http://${COMFYUI_HOST}:${COMFYUI_PORT}"
if [ "$ENABLE_JUPYTER" = "true" ]; then
    echo "📓 Jupyter: http://${COMFYUI_HOST}:${JUPYTER_PORT}"
fi
echo "📁 Logs: /mnt/netdrive/comfyui/"
echo "======================================="
echo ""

# Keep container running
wait $COMFYUI_PID