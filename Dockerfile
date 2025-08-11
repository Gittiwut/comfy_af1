FROM ubuntu:22.04
ARG PYTHON_VERSION=3.12

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    COMFYUI_ROOT=/mnt/netdrive/comfyui \
    VENV_PATH=/mnt/netdrive/python_env \
    JUPYTER_CONFIG_DIR=/mnt/netdrive/config/jupyter \
    PATH="/mnt/netdrive/python_env/bin:/root/.cargo/bin:${PATH}" \
    TMPDIR=/mnt/netdrive/tmp

# Set ComfyUI root path
WORKDIR /mnt/netdrive/comfyui

# Create necessary directories
RUN mkdir -p /mnt/netdrive/comfyui \
             /mnt/netdrive/python_env \
             /mnt/netdrive/config/jupyter \
             /mnt/netdrive/tools \
             /mnt/netdrive/tmp

# system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip python3-dev \
    git curl wget ca-certificates build-essential pkg-config \
    libgl1 libglib2.0-0 aria2 ffmpeg && \
  rm -rf /var/lib/apt/lists/*

# install UV
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
cp /root/.local/bin/uv /usr/local/bin/ && \
/usr/local/bin/uv --version

# Copy files
COPY requirements.txt /requirements.txt
COPY entrypoint.sh /entrypoint.sh
COPY custom_nodes_list.json /custom_nodes_list.json
COPY setup_custom_nodes.py /setup_custom_nodes.py
COPY download_models.py /download_models.py
COPY models_config.json /models_config.json

# Set permissions
RUN chmod +x /entrypoint.sh

# Expose ports
EXPOSE 8188 8888

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8188/ || exit 1

# Set entrypoint
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
CMD []