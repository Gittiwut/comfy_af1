#!/bin/bash
set -eo pipefail

echo "[ENTRYPOINT] Starting container..."

# กำหนด path
COMFYUI_DIR="${COMFYUI_ROOT:-/mnt/netdrive/comfyui}"
VENV_PATH="/mnt/netdrive/python_env"
JUPYTER_CONFIG_DIR="/mnt/netdrive/config/jupyter"

# ตรวจสอบว่า uv มีอยู่หรือไม่
if ! command -v uv &> /dev/null; then
    echo "[ERROR] UV not found! Please check Dockerfile installation."
    exit 1
fi
echo "[INFO] UV found: $(which uv)"

# สร้าง Virtual Environment
if [ ! -f "${VENV_PATH}/bin/python" ]; then
    echo "[SETUP] Creating Python virtual environment..."
    python3 -m venv ${VENV_PATH}
    ${VENV_PATH}/bin/python -m pip install --upgrade pip
fi

# Activate virtual environment
export PATH="${VENV_PATH}/bin:${PATH}"

# ติดตั้ง dependencies จาก requirements.txt
if [ -f "/requirements.txt" ]; then
    echo "[SETUP] Installing dependencies from requirements.txt..."
    uv pip install --python=${VENV_PATH}/bin/python --no-cache -r /requirements.txt
else
    echo "[WARNING] requirements.txt not found at /requirements.txt"
fi

# ติดตั้ง config jupyter
if [ ! -f "${VENV_PATH}/bin/jupyter" ]; then
    echo "[SETUP] Installing Jupyter..."
    uv pip install --python=${VENV_PATH}/bin/python --no-cache jupyter jupyterlab
  fi

# Create Jupyter config (ครั้งแรกเท่านั้น)
export JUPYTER_CONFIG_DIR=${JUPYTER_CONFIG_DIR}
if [ ! -f "${JUPYTER_CONFIG_DIR}/jupyter_notebook_config.py" ]; then
    echo "[SETUP] Configuring Jupyter..."
    mkdir -p ${JUPYTER_CONFIG_DIR}
    ${VENV_PATH}/bin/jupyter notebook --generate-config
    
    # Add Jupyter configuration
    cat >> ${JUPYTER_CONFIG_DIR}/jupyter_notebook_config.py << EOF
c.NotebookApp.allow_root = True
c.NotebookApp.ip = '0.0.0.0'
c.NotebookApp.token = ''
c.NotebookApp.password = ''
c.NotebookApp.allow_origin = '*'
c.NotebookApp.allow_remote_access = True
EOF
fi  

# start jupyter notebook
if [ "$ENABLE_JUPYTER" = "true" ]; then
    echo "[STARTUP] Starting Jupyter Lab on port 8888..."
    
    # Kill any existing Jupyter processes
    pkill -f jupyter 2>/dev/null || true
    
    # Start Jupyter with better error handling
    ${VENV_PATH}/bin/jupyter lab --port=8888 --no-browser --allow-root \
        --ServerApp.token='' --ServerApp.password='' \
        --ServerApp.allow_origin='*' \
        --ServerApp.root_dir=/mnt/netdrive \
        --ServerApp.allow_remote_access=True \
        --ServerApp.open_browser=False \
        --ServerApp.port_retries=0 &
    
    # Wait a bit and check if Jupyter started successfully
    sleep 5
    if pgrep -f jupyter > /dev/null; then
        echo "[STARTUP] ✅ Jupyter Lab started successfully on port 8888"
    else
        echo "[STARTUP] ❌ Jupyter Lab failed to start"
        echo "[STARTUP] Checking Jupyter logs..."
        ${VENV_PATH}/bin/jupyter lab --no-browser --allow-root \
            --ServerApp.token='' --ServerApp.password='' \
            --ServerApp.allow_origin='*' 2>&1 | head -20
    fi
fi

# ตรวจสอบว่ามีโฟลเดอร์ ComfyUI หรือไม่ ถ้าไม่มีก็ clone
if [ ! -d "$COMFYUI_DIR" ] || [ -z "$(ls -A "$COMFYUI_DIR" 2>/dev/null)" ]; then
  echo "[ENTRYPOINT] ComfyUI directory not found. Cloning from GitHub..."
    git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
fi

# ติดตั้ง ComfyUI requirements (ถ้ามี)
if [ -f "$COMFYUI_DIR/requirements.txt" ]; then
    echo "[SETUP] Installing ComfyUI requirements..."
    uv pip install --python=${VENV_PATH}/bin/python --no-cache -r "$COMFYUI_DIR/requirements.txt"
else
    echo "[INFO] ComfyUI requirements.txt not found"
fi

# System Information
echo "[INFO] Using Python: $(which python)"
echo "[INFO] Python version: $(python --version)"

# Check GPU availability
if command -v nvidia-smi &> /dev/null; then
  echo "[ENTRYPOINT] GPU detected:"
  nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits | head -3
else
  echo "[ENTRYPOINT] No GPU detected, running in CPU mode"
fi

# Check PyTorch CUDA availability
echo "[ENTRYPOINT] Checking PyTorch CUDA availability..."
python3 -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'CUDA device count: {torch.cuda.device_count()}')
    print(f'CUDA device name: {torch.cuda.get_device_name(0)}')
else:
    print('No CUDA devices found')
"

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

# Add CPU-only flag if no GPU
if ! command -v nvidia-smi &> /dev/null || ! python3 -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
  echo "[ENTRYPOINT] Adding --cpu flag (no GPU available)"
  ARGS+=(--cpu)
fi

# Show memory usage before start
if command -v nvidia-smi &> /dev/null; then
  echo "[ENTRYPOINT] GPU Memory before start:"
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits
fi

echo "[ENTRYPOINT] Starting ComfyUI with args: ${ARGS[*]}"

# Copy wrapper script to ComfyUI directory
cp /comfyui_wrapper.py "$COMFYUI_DIR/comfyui_wrapper.py"

# Execute ComfyUI with auto-install wrapper
exec python3 "$COMFYUI_DIR/comfyui_wrapper.py" "${ARGS[@]}"