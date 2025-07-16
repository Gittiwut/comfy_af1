#!/bin/bash
set -eo pipefail

echo "[ENTRYPOINT] Starting container..."

# =============================
# ✅ กำหนด path และสร้าง folder ComfyUI
COMFYUI_DIR="${COMFYUI_ROOT:-/mnt/netdrive/comfyui}"
TEMP_BACKUP_DIR="/mnt/netdrive/comfyui_backup"
PRESERVE_DIRS=(models output workflows custom_nodes input notebooks user)
PYTHON_MODULE_DIR="/mnt/netdrive/python_packages" 
BASE_FILE_LIST="/mnt/netdrive/.base_file_list.txt"
REQ_FILE="$COMFYUI_DIR/requirements.txt"
CUSTOM_NODE_DIR="$COMFYUI_DIR/custom_nodes"
MODEL_BASE="$COMFYUI_DIR/models"

# =============================
# ✅ สร้าง folder ที่จำเป็น
mkdir -p "$PYTHON_MODULE_DIR"
cd / || exit 1

# =============================
# ✅ เพิ่ม PYTHONPATH ให้ Python มองเห็น module ที่อยู่บน network volume
export PYTHONPATH="$PYTHON_MODULE_DIR:$PYTHONPATH"

# =============================
# ✅ เพิ่มระบบ backup / restore / rsync
backup_important_folders() {
  echo "[BACKUP] Backing up important folders..."
  rm -rf "$TEMP_BACKUP_DIR"
  mkdir -p "$TEMP_BACKUP_DIR"
  for dir in "${PRESERVE_DIRS[@]}"; do
    if [ -d "$COMFYUI_DIR/$dir" ]; then
      echo " - Backing up $dir"
      cp -r "$COMFYUI_DIR/$dir" "$TEMP_BACKUP_DIR/"
    fi
  done
}

restore_backup() {
  echo "[RESTORE] Restoring backed up folders..."
  if [ ! -d "$TEMP_BACKUP_DIR" ]; then
    echo "[RESTORE] ⚠️ No backup found! Skipping restore."
    return
  fi

  for dir in "${PRESERVE_DIRS[@]}"; do
    if [ -d "$TEMP_BACKUP_DIR/$dir" ]; then
      echo " - Restoring $dir with rsync"
      rsync -a "$TEMP_BACKUP_DIR/$dir/" "$COMFYUI_DIR/$dir/"
    fi
  done
  rm -rf "$TEMP_BACKUP_DIR"
}

# ✅ ติดตั้ง essential packages
echo "[ENTRYPOINT] Installing essential packages..."
ESSENTIAL_PACKAGES="comfy-cli websocket-client aiohttp"
for package in $ESSENTIAL_PACKAGES; do
  if ! python3 -c "import ${package//-/_}" &>/dev/null 2>&1; then
    echo "[ENTRYPOINT] Installing $package..."
    pip install --no-cache-dir "$package"
  fi
done

# ✅ บันทึก base file list ComfyUI
if [ ! -f "$BASE_FILE_LIST" ]; then
  echo "[CLONE] First time setup. Cloning ComfyUI..."
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"

  echo "[INIT] Saving base file list..."
  find "$COMFYUI_DIR" -type f \
    -not -path "$COMFYUI_DIR/models/*" \
    -not -path "$COMFYUI_DIR/custom_nodes/*" \
    -not -path "$COMFYUI_DIR/workflows/*" \
    -not -path "$COMFYUI_DIR/output/*" \
    -not -path "$COMFYUI_DIR/user/*" \
    > "$BASE_FILE_LIST"

else
  echo "[CHECK] Verifying comfyUI file integrity..."
  MISSING_CORE=false
  while read -r file; do
    if [ ! -f "$file" ]; then
      echo "[CHECK] Missing: $file"
      MISSING_CORE=true
      break
    fi
  done < "$BASE_FILE_LIST"

  if [ "$MISSING_CORE" = true ]; then
    echo "[RECOVERY] Core files missing. Re-cloning ComfyUI..."
    backup_important_folders
    rm -rf "$COMFYUI_DIR"
    git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
    restore_backup
  else
    echo "[CHECK] All core files present. Skipping re-clone."
  fi
fi

# ✅ ตรวจสอบ & ติดตั้ง Python module ที่ขาด
if [ -f "$REQ_FILE" ]; then
  echo "[ENTRYPOINT] Checking requirements..."
  pip install --no-cache-dir -r "$REQ_FILE"
else
  echo "[ENTRYPOINT] No requirements.txt found, skipping..."
fi

# =============================
# ✅ Ensure jq is installed
if ! command -v jq &>/dev/null; then
  echo "[DEPENDENCY] jq not found. Installing..."
  apt-get update && apt-get install -y jq
fi

# ============================
# ✅ Preload Models
MODEL_CONFIG_JSON="/mnt/netdrive/models_config.json"

if [ ! -f "$MODEL_CONFIG_JSON" ]; then
  echo "[INIT] Restoring models_config.json"
  cp /opt/models_config.json "$MODEL_CONFIG_JSON"
fi

if [ -d "$MODEL_BASE" ]; then
  echo "[PRELOAD] Detected models folder. Starting preload from $MODEL_CONFIG_JSON..."

  for category in checkpoints vae unet diffusion_models text_encoders loras upscale_models controlnet clip_vision ipadapter style_models clip; do
    MODEL_DIR="$MODEL_BASE/$category"
    URLS=$(jq -r --arg cat "$category" '.[$cat][]?' "$MODEL_CONFIG_JSON")

    for url in $URLS; do
      filename=$(basename "$url")
      dest="$MODEL_DIR/$filename"

      if [ ! -f "$dest" ]; then
        echo " - Downloading $filename to $MODEL_DIR"
        mkdir -p "$MODEL_DIR"
        curl -L -o "$dest" "$url"
      else
        echo " - Skipping $filename (already exists)"
      fi
    done
  done
else
  echo "[PRELOAD] Skipping model preload: $MODEL_BASE not found."
fi

# ============================
# ✅ Preload Custom Nodes
CUSTOM_NODE_CONFIG_JSON="/mnt/netdrive/custom_nodes_list.json"

if [ ! -f "$CUSTOM_NODE_CONFIG_JSON" ]; then
  echo "[INIT] Restoring custom_nodes_list.json"
  cp /opt/custom_nodes_list.json "$CUSTOM_NODE_CONFIG_JSON"
fi

if [ -d "$CUSTOM_NODE_DIR" ]; then
  echo "[PRELOAD] Detected custom_nodes folder. Starting preload from $CUSTOM_NODE_CONFIG_JSON..."

  CUSTOM_NODE_KEYS=$(jq -r 'keys[]' "$CUSTOM_NODE_CONFIG_JSON")

  for key in $CUSTOM_NODE_KEYS; do
    urls=$(jq -r --arg key "$key" '.[$key][]' "$CUSTOM_NODE_CONFIG_JSON")
    dest_dir="$CUSTOM_NODE_DIR/$key"

    if [ -d "$dest_dir" ]; then
      echo " - Skipping $key (already exists)"
      continue
    fi

    for url in $urls; do
      echo " - Cloning $key from $url"
      git clone "$url" "$dest_dir" && break || echo "   ⚠️ Failed: $url"
    done
  done
else
  echo "[PRELOAD] Skipping custom_nodes preload: $CUSTOM_NODE_DIR not found."
fi

# ✅ รัน JupyterLab แยก background
echo "[ENTRYPOINT] Starting JupyterLab..."
mkdir -p /mnt/netdrive/notebooks

# Kill any existing Jupyter processes
pkill -f jupyter || true

nohup jupyter lab \
    --ip=0.0.0.0 \
    --port=8888 \
    --allow-root \
    --no-browser \
    --notebook-dir="/mnt/netdrive" \
    --ServerApp.token="" \
    --ServerApp.password="" \
    --ServerApp.allow_origin="*" \
    --ServerApp.allow_remote_access=True \
    --ServerApp.disable_check_xsrf=True \
    --KernelManager.cull_idle_timeout=0 \
    > /mnt/netdrive/jupyter.log 2>&1 &

JUPYTER_PID=$!

sleep 5

if kill -0 $JUPYTER_PID 2>/dev/null; then
    echo "[ENTRYPOINT] ✅ JupyterLab started successfully (PID: $JUPYTER_PID)"
    echo "[ENTRYPOINT] Access at: http://localhost:8888"
else
    echo "[ENTRYPOINT] ❌ Failed to start JupyterLab"
    echo "[ENTRYPOINT] Error log:"
    tail -n 20 /mnt/netdrive/jupyter.log
fi

# ✅ ให้ ComfyUI เป็น process หลัก (PID 1)
echo "[ENTRYPOINT] Starting ComfyUI..."
echo "[ENTRYPOINT] ComfyUI will be available at: http://localhost:8188"

# Create web directory if missing
mkdir -p "$COMFYUI_DIR/web"

# Check if ComfyUI files exist
if [ ! -f "$COMFYUI_DIR/main.py" ]; then
    echo "[ERROR] ComfyUI main.py not found!"
    echo "[ERROR] Directory contents:"
    ls -la "$COMFYUI_DIR"
    exit 1
fi

# Start ComfyUI with error logging
exec python3 "$COMFYUI_DIR/main.py" \
    --listen 0.0.0.0 \
    --port 8188 \
    --preview-method auto \
    2>&1 | tee /mnt/netdrive/comfyui.log