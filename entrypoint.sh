#!/bin/bash
set -eo pipefail

echo "[ENTRYPOINT] Starting container..."

# กำหนด path
export COMFYUI_DIR="/mnt/netdrive/comfyui"
export COMFYUI_CUSTOM_NODES="$COMFYUI_DIR/custom_nodes"
export COMFYUI_MODELS="$COMFYUI_DIR/models"
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

# ตั้งค่า TMPDIR ก่อนรัน Debug
mkdir -p /mnt/netdrive/tmp

# Debug TMPDIR Directory
echo "[DEBUG] TMPDIR Directory:"
ls -ld /mnt/netdrive/tmp
echo "[DEBUG] TMPDIR Write Test:"
touch /mnt/netdrive/tmp/testfile && echo "Write OK" || echo "Write FAIL"
echo "[DEBUG] TMPDIR Remove Test:"
rm -f /mnt/netdrive/tmp/testfile

# Debug disk usage after TMPDIR setup
echo "[DEBUG] Disk usage after TMPDIR setup:"
df -h /
df -h /mnt/netdrive

if [ ! -d "/mnt/netdrive/tmp" ]; then
    echo "[ERROR] /mnt/netdrive/tmp does not exist or cannot be created!"
    exit 1
fi
export TMPDIR=/mnt/netdrive/tmp
echo "[DEBUG] TMPDIR set to: $TMPDIR"

# ติดตั้ง dependencies จาก requirements.txt
if [ -f "/requirements.txt" ]; then
    echo "[SETUP] Installing dependencies from requirements.txt..."
    uv pip install --python=${VENV_PATH}/bin/python --no-cache -r /requirements.txt
    echo "[DEBUG] Disk usage after requirements install:"
    df -h /
    df -h /mnt/netdrive
else
    echo "[WARNING] requirements.txt not found at /requirements.txt"
fi

# ติดตั้ง config jupyter
if [ ! -f "${VENV_PATH}/bin/jupyter" ]; then
    echo "[SETUP] Installing Jupyter..."
    uv pip install --python=${VENV_PATH}/bin/python --no-cache jupyter jupyterlab
    echo "[DEBUG] Disk usage after Jupyter install:"
    df -h /
    df -h /mnt/netdrive
  fi

# Create Jupyter config
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
    
    # Start Jupyter in background
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
    echo "[DEBUG] Disk usage after ComfyUI requirements install:"
    df -h /
    df -h /mnt/netdrive
else
    echo "[INFO] ComfyUI requirements.txt not found"
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

# Custom Nodes & Models Setup
python3 /setup_custom_nodes.py
echo "[DEBUG] Disk usage after setup_custom_nodes.py:"
df -h /
df -h /mnt/netdrive
# Clean up temp after custom nodes setup
echo "[CLEANUP] Cleaning up /mnt/netdrive/tmp after custom nodes setup..."
rm -rf /mnt/netdrive/tmp/* || true

python3 /download_models.py
echo "[DEBUG] Disk usage after download_models.py:"
df -h /
df -h /mnt/netdrive
# Clean up temp after model download
echo "[CLEANUP] Cleaning up /mnt/netdrive/tmp after model download..."
rm -rf /mnt/netdrive/tmp/* || true

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

# === [Custom Nodes & Models Setup] ===
CUSTOM_NODES_JSON="/custom_nodes_list.json"
if [ -f "$CUSTOM_NODES_JSON" ]; then
  echo "[SETUP] Cloning custom nodes from $CUSTOM_NODES_JSON ..."
  cd "$COMFYUI_DIR/custom_nodes"
  python3 -c "
import json, subprocess
with open('$CUSTOM_NODES_JSON') as f:
    nodes = json.load(f)
for name, repos in nodes.items():
    for repo in repos:
        folder = name
        print(f'Cloning {repo} into {folder} ...')
        subprocess.run(['git', 'clone', '--depth=1', repo, folder])
"
  # ติดตั้ง dependencies ของ custom nodes
  find "$COMFYUI_DIR/custom_nodes" -name "requirements.txt" -exec uv pip install --python=${VENV_PATH}/bin/python --no-cache -r {} \;
else
  echo "[WARNING] $CUSTOM_NODES_JSON not found, skipping custom nodes setup."
fi

MODELS_CONFIG_JSON="/models_config.json"
if [ -f "$MODELS_CONFIG_JSON" ]; then
  echo "[SETUP] Downloading models from $MODELS_CONFIG_JSON ..."
  python3 /download_models.py --config "$MODELS_CONFIG_JSON" --base "$COMFYUI_DIR/models"
else
  echo "[WARNING] $MODELS_CONFIG_JSON not found, skipping model download."
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

# Start ComfyUI in background
python3 "$COMFYUI_DIR/comfyui_wrapper.py" "${ARGS[@]}" &

# Wait for all background jobs
wait