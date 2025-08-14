#!/bin/bash
# Universal ComfyUI Builder for Multi-GPU Support - FINAL VERSION
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
echo "⚠️  NO TIMEOUT: Optimized for slow internet connections"
echo "   - Downloads will complete regardless of time"
echo "   - Git clones will not timeout"
echo "   - Package installations will wait as needed"

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

# Validate constraints files content
echo "🔍 Validating constraints files..."
for constraints_file in constraints/*.txt; do
    if [[ -f "$constraints_file" ]]; then
        # Check if file contains torch entry
        if grep -q "^torch==" "$constraints_file"; then
            echo "  ✅ $constraints_file (contains torch specification)"
        else
            echo "  ⚠️  $constraints_file (no torch specification found)"
        fi
        
        # Check for empty files
        if [[ ! -s "$constraints_file" ]]; then
            echo "  ❌ $constraints_file is empty"
            exit 1
        fi
    else
        echo "  ❌ $constraints_file not found"
        exit 1
    fi
done

# Validate JSON files
echo "🔍 Validating JSON files..."
for json_file in custom_nodes_list.json models_config.json; do
    if python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
        echo "  ✅ $json_file (valid JSON)"
    else
        echo "  ❌ $json_file (invalid JSON)"
        exit 1
    fi
done

# Create constraints directory if it doesn't exist
mkdir -p constraints

echo "📋 Available constraints files:"
ls -la constraints/

# Validate Python scripts
echo "🔍 Validating Python scripts..."
for py_file in setup_custom_nodes.py download_models.py smoke_test.py; do
    if python3 -m py_compile "$py_file" 2>/dev/null; then
        echo "  ✅ $py_file (syntax OK)"
    else
        echo "  ❌ $py_file (syntax error)"
        exit 1
    fi
done

# Build the image
echo "🔨 Building Docker image..."
echo "Command: docker build --build-arg PYTHON_VERSION=${PYTHON_VERSION} ${BUILD_ARGS} -t ${IMAGE_NAME}:${TAG} ."

if docker build \
    --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
    ${BUILD_ARGS} \
    -t "${IMAGE_NAME}:${TAG}" \
    .; then
    echo "✅ Build completed successfully!"
else
    echo "❌ Build failed!"
    exit 1
fi

# Show image info
echo "📊 Image Information:"
docker images "${IMAGE_NAME}:${TAG}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"

# Validate image can start
echo "🔍 Validating image can start..."
if docker run --rm "${IMAGE_NAME}:${TAG}" python3 --version &>/dev/null; then
    echo "✅ Image validation: PASSED"
else
    echo "❌ Image validation: FAILED"
    exit 1
fi

# Optional: Run smoke tests
if [[ "${RUN_TESTS:-false}" == "true" ]]; then
    echo "🧪 Running smoke tests..."
    
    # Create test container
    if docker run --rm --gpus all \
        -v /tmp/comfyui-test:/mnt/netdrive \
        "${IMAGE_NAME}:${TAG}" \
        python3 /smoke_test.py; then
        echo "✅ Smoke tests completed successfully"
    else
        echo "⚠️  Smoke tests failed - check GPU availability"
    fi
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
echo ""
echo "🎯 Next steps:"
echo "  1. Test on your target GPU"
echo "  2. Push to registry: docker push ${IMAGE_NAME}:${TAG}"
echo "  3. Deploy on Runpod"