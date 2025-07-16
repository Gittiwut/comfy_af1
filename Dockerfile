FROM python:3.10-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    --no-install-recommends \
    git curl bash wget \
    build-essential \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    libglu1-mesa \
    libgl1-mesa-glx \
    libcairo2-dev \
    pkg-config \
    python3-dev \
    ffmpeg \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Set ComfyUI root path
ENV COMFYUI_ROOT=/mnt/netdrive/comfyui
WORKDIR /mnt/netdrive/comfyui

# Install Python packages
COPY requirements.txt /mnt/netdrive/comfyui/requirements.txt
RUN pip install --no-cache-dir -r /mnt/netdrive/comfyui/requirements.txt

# Copy entrypoint scriptCOPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy configuration files
COPY custom_nodes_list.json /opt/custom_nodes_list.json
COPY models_config.json /opt/models_config.json

# Create necessary directories
RUN mkdir -p /mnt/netdrive/comfyui /mnt/netdrive/python_packages

# Expose ports for RunPod
EXPOSE 8188
EXPOSE 8888

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
CMD []