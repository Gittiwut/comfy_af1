ARG PYTHON_VERSION=3.12
ARG TARGETARCH=amd64

# ใช้ CUDA base image
FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04

# Environment variables
ENV COMFYUI_ROOT=/mnt/netdrive/comfyui \
    VENV_PATH=/mnt/netdrive/python_env \
    JUPYTER_CONFIG_DIR=/mnt/netdrive/config/jupyter \
    DEBIAN_FRONTEND=noninteractive \
    PATH="/mnt/netdrive/python_env/bin:/root/.cargo/bin:${PATH}" \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Set ComfyUI root path
WORKDIR /mnt/netdrive/comfyui

# ติดตั้ง system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    ca-certificates \
    software-properties-common \
    build-essential \
    libgl1-mesa-dev \
    libglib2.0-0 \
    ffmpeg \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ติดตั้ง UV
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    cp /root/.local/bin/uv /usr/local/bin/ && \
    /usr/local/bin/uv --version

# Create necessary directories
RUN mkdir -p /mnt/netdrive/comfyui \
             /mnt/netdrive/python_env \
             /mnt/netdrive/config/jupyter \
             /mnt/netdrive/tools

# Copy files
COPY requirements.txt /requirements.txt
COPY entrypoint.sh /entrypoint.sh
COPY comfyui_wrapper.py /comfyui_wrapper.py

# Set permissions
RUN chmod +x /entrypoint.sh

# Expose ports - รวมจากทั้งสองแบบ
EXPOSE 8188 8888

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8188/ || exit 1

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
CMD []