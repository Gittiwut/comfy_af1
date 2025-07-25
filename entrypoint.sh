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
export TMPDIR=/mnt/netdrive/tmp

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

# ติดตั้ง aiohttp และ aiofiles
echo "[SETUP] Installing parallel processing dependencies..."
uv pip install --python=${VENV_PATH}/bin/python --no-cache aiohttp aiofiles

# ติดตั้ง dependencies จาก requirements.txt แบบ parallel
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
    echo "[DEBUG] Starting ComfyUI requirements installation at $(date)"
    echo "[DEBUG] Requirements file size: $(wc -l < "$COMFYUI_DIR/requirements.txt") lines"
    
    # เพิ่ม Network Check
    echo "[DEBUG] Network connectivity check..."
    if curl -s --connect-timeout 5 --max-time 10 https://pypi.org/simple/ > /dev/null; then
        echo "[DEBUG] Network connectivity: OK (PyPI accessible)"
    elif curl -s --connect-timeout 5 --max-time 10 https://github.com > /dev/null; then
        echo "[DEBUG] Network connectivity: OK (GitHub accessible)"
    else
        echo "[DEBUG] Network connectivity: SLOW/FAILED"
    fi

    # เพิ่ม progress indicator
    uv pip install --python=${VENV_PATH}/bin/python --no-cache -r "$COMFYUI_DIR/requirements.txt" 2>&1 | while IFS= read -r line; do
        echo "[REQ_PROGRESS] $line"
    done
    
    echo "[DEBUG] ComfyUI requirements installation completed at $(date)"
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
python3 /setup_custom_nodes.py > /mnt/netdrive/comfyui/setup_custom_nodes.log 2>&1 &
CUSTOM_NODES_PID=$!
echo "[SETUP] Starting models download..."
python3 /download_models.py > /mnt/netdrive/comfyui/download_models.log 2>&1 &
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

# Add CPU-only flag if no GPU
if ! command -v nvidia-smi &> /dev/null || ! python3 -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
  echo "[ENTRYPOINT] Adding --cpu flag (no GPU available)"
  ARGS+=(--cpu)
fi

# Show memory usage before start
if command -v nvidia-smi &> /dev/null; then
  echo "[ENTRYPOINT] GPU Memory before start at $(date):"
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits
fi

# ComfyUI startup
echo "[ENTRYPOINT] Starting ComfyUI with args: ${ARGS[*]}"
python3 main.py "${ARGS[@]}" 2>&1 | tee /mnt/netdrive/comfyui/main.log &
COMFYUI_PID=$!

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
    if curl -s http://0.0.0.0:8188 > /dev/null 2>&1; then
        echo "[HEALTHCHECK] ✅ ComfyUI is up after $((i*30)) seconds."
        break
    fi
    echo "[HEALTHCHECK] ...not ready yet (waited $((i*30)) seconds)"
    sleep 30
done

# Notify if ComfyUI did not start within 10 rounds
if ! curl -s http://0.0.0.0:8188 > /dev/null 2>&1; then
    echo "[HEALTHCHECK] ⚠️  ComfyUI did not start within $((MAX_ROUNDS*30)) seconds."
fi

echo "[ENTRYPOINT] Pod ready"
sleep infinity