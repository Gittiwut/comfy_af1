#!/bin/bash
# Universal ComfyUI Builder for Multi-GPU Support
# Supports: RTX 4090 (Ada) → RTX 5090 (Blackwell) → H100 (Hopper) → B200 (Blackwell)

set -euo pipefail

# Configuration
IMAGE_NAME="${IMAGE_NAME:-comfyui-universal}"
TAG="${TAG:-latest}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
BUILD_ARGS="${BUILD_ARGS:-}"

echo "🏗️ Universal ComfyUI Builder"
echo "================================"
echo "📦 Image: ${IMAGE_NAME}:${TAG}"
echo "🐍 Python: ${PYTHON_VERSION}"

# Verify required files exist
REQUIRED_FILES=(
    "Dockerfile"
    "entrypoint.sh" 
    "requirements.txt"
    "constraints/constraints_ada.txt"
    "constraints/constraints_hopper.txt"
    "constraints/constraints_blackwell.txt"
    "custom_nodes_list.json"
    "setup_custom_nodes.py"
    "download_models.py"
    "models_config.json"
    "smoke_test.py"
)

echo "🔍 Verifying required files..."
for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "❌ Missing required file: $file"
        exit 1
    fi
    echo "  ✅ $file"
done

# Create constraints directory if it doesn't exist
mkdir -p constraints

echo "📋 Available constraints files:"
ls -la constraints/

# Build the image
echo "🔨 Building Docker image..."
echo "Command: docker build --build-arg PYTHON_VERSION=${PYTHON_VERSION} ${BUILD_ARGS} -t ${IMAGE_NAME}:${TAG} ."

docker build \
    --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
    ${BUILD_ARGS} \
    -t "${IMAGE_NAME}:${TAG}" \
    .

echo "✅ Build completed successfully!"

# Show image info
echo "📊 Image Information:"
docker images "${IMAGE_NAME}:${TAG}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"

# Optional: Run smoke tests
if [[ "${RUN_TESTS:-false}" == "true" ]]; then
    echo "🧪 Running smoke tests..."
    
    # Create test container
    docker run --rm --gpus all \
        -v /tmp/comfyui-test:/mnt/netdrive \
        "${IMAGE_NAME}:${TAG}" \
        python3 /smoke_test.py
        
    echo "✅ Smoke tests completed"
fi

echo ""
echo "🎉 Universal ComfyUI Image Ready!"
echo "================================"
echo "📦 Image: ${IMAGE_NAME}:${TAG}"
echo "🚀 Usage examples:"
echo ""
echo "# RTX 4090/3090 (Ada/Ampere):"
echo "docker run --gpus all -p 8188:8188 -v /path/to/data:/mnt/netdrive ${IMAGE_NAME}:${TAG}"
echo ""
echo "# H100 (Hopper):"
echo "docker run --gpus all -p 8188:8188 -v /path/to/data:/mnt/netdrive ${IMAGE_NAME}:${TAG}"
echo ""
echo "# RTX 5090/B200 (Blackwell):"
echo "docker run --gpus all -p 8188:8188 -v /path/to/data:/mnt/netdrive ${IMAGE_NAME}:${TAG}"
echo ""
echo "📓 Access URLs:"
echo "  🌐 ComfyUI: http://localhost:8188"
echo "  📔 Jupyter: http://localhost:8888" 
echo ""
echo "🔬 Run smoke tests:"
echo "docker run --rm --gpus all -v /tmp/test:/mnt/netdrive ${IMAGE_NAME}:${TAG} python3 /smoke_test.py"