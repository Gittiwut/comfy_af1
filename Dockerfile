# Multi-GPU Universal ComfyUI Image
# Supports: RTX 4090 (Ada) → RTX 5090 (Blackwell) → H100 (Hopper) → B200 (Blackwell)
FROM nvidia/cuda:12.8.1-runtime-ubuntu22.04

ARG PYTHON_VERSION=3.11
ARG TARGETARCH=amd64

# For Blackwell support
ENV TORCH_CUDA_ARCH_LIST="8.9;9.0;10.0;12.0;12.0+PTX" \
    XFORMERS_BUILD_WITH_CUDA="1" \
    FORCE_CUDA="1" \
    CUDA_MODULE_LOADING="LAZY" \
    PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True,max_split_size_mb:128" \
    MAX_JOBS="4"

# Universal environment variables - minimal but effective
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    CUDA_MODULE_LOADING=LAZY \
    COMFYUI_ROOT=/mnt/netdrive/comfyui \
    VENV_ROOT=/mnt/netdrive/python_envs \
    PIP_CACHE_DIR=/mnt/netdrive/pip_cache \
    COMPUTE_CACHE_DIR=/mnt/netdrive/.nv/ComputeCache \
    JUPYTER_CONFIG_DIR=/mnt/netdrive/config/jupyter \
    TMPDIR=/mnt/netdrive/tmp

# Set ComfyUI root path
WORKDIR /mnt/netdrive/comfyui

# Create necessary directories including compute cache
RUN mkdir -p /mnt/netdrive/comfyui \
             /mnt/netdrive/python_envs \
             /mnt/netdrive/pip_cache \
             /mnt/netdrive/.nv/ComputeCache \
             /mnt/netdrive/config/jupyter \
             /mnt/netdrive/tools \
             /mnt/netdrive/tmp

# Install system dependencies - streamlined for multi-GPU support
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common && \
    add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update && apt-get install -y --no-install-recommends \
    python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev \
    git curl wget ca-certificates build-essential pkg-config \
    libgl1 libglib2.0-0 aria2 ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install UV for faster dependency management
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    cp /root/.local/bin/uv /usr/local/bin/ && \
    /usr/local/bin/uv --version

# Copy configuration files and constraints
COPY requirements.txt /requirements.txt
COPY entrypoint.sh /entrypoint.sh
COPY custom_nodes_list.json /custom_nodes_list.json
COPY setup_custom_nodes.py /setup_custom_nodes.py
COPY download_models.py /download_models.py
COPY models_config.json /models_config.json

# Copy architecture-specific constraints
COPY constraints/ /constraints/

# Set permissions
RUN chmod +x /entrypoint.sh

# Expose ports
EXPOSE 8188 8888

# Set entrypoint
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
CMD []