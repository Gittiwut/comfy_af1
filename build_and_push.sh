#!/bin/bash

# Build script for RunPod deployment

echo "🚀 Building ComfyUI Docker image for RunPod..."

# Docker Hub username
DOCKER_USERNAME="your-dockerhub-username"
IMAGE_NAME="comfyui-runpod"
TAG="latest"

# Build the image
echo "📦 Building Docker image..."
docker build -t $DOCKER_USERNAME/$IMAGE_NAME:$TAG .

# Test locally (optional)
echo "🧪 Do you want to test locally first? (y/n)"
read -r response
if [[ "$response" == "y" ]]; then
    echo "🏃 Running container locally..."
    docker run -d \
        -p 8188:8188 \
        -p 8888:8888 \
        --name comfyui-test \
        $DOCKER_USERNAME/$IMAGE_NAME:$TAG
    
    echo "✅ Container running!"
    echo "ComfyUI: http://localhost:8188"
    echo "JupyterLab: http://localhost:8888"
    echo ""
    echo "To stop: docker stop comfyui-test && docker rm comfyui-test"
fi

# Push to Docker Hub
echo "📤 Push to Docker Hub? (y/n)"
read -r response
if [[ "$response" == "y" ]]; then
    docker push $DOCKER_USERNAME/$IMAGE_NAME:$TAG
    echo "✅ Image pushed successfully!"
    echo "Use this image in RunPod: $DOCKER_USERNAME/$IMAGE_NAME:$TAG"
fi
