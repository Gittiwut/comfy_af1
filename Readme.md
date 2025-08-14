# Universal ComfyUI Docker Image

**One Image, All GPUs**: RTX 4090 (Ada) → RTX 5090 (Blackwell) → H100 (Hopper) → B200 (Blackwell)

## 🎯 Features

- **Universal GPU Support**: Automatically detects and optimizes for your GPU architecture
- **Architecture-Specific Optimization**: Different PyTorch/CUDA configurations per GPU family
- **Future-Proof**: PTX fallback for newer architectures not yet supported
- **Runpod Ready**: Optimized for cloud GPU providers
- **Performance Optimized**: Tensor cores, mixed precision, flash attention support

## 🏗️ Supported Architectures

| GPU Family | Example GPUs | Compute Capability | Optimization Level |
|------------|--------------|-------------------|-------------------|
| **Blackwell** | RTX 5090, B200 | 10.0+ | Bleeding Edge |
| **Hopper** | H100, H800 | 9.0 | Enterprise |
| **Ada Lovelace** | RTX 4090, RTX 4080 | 8.9 | High Performance |
| **Ampere** | RTX 3090, A100 | 8.6 | Stable (Fallback) |

## 🚀 Quick Start

### Basic Usage
```bash
# Build the image
./build.sh

# Run on any supported GPU
docker run --gpus all -p 8188:8188 -v /your/data:/mnt/netdrive comfyui-universal:latest
```

### Runpod Deployment
```bash
# Template configuration
Image: your-registry/comfyui-universal:latest
Container Disk: 50GB
Volume Mount: /mnt/netdrive
Expose Ports: 8188, 8888
```

## 🔧 Architecture Detection

The image automatically detects your GPU and selects the optimal configuration:

```bash
🎯 [GPU] Detected: NVIDIA GeForce RTX 5090
📊 [GPU] Compute Capability: 10.0
⚡ [ARCH] Blackwell detected (RTX 5090/B200 class)
🏗️  [ARCH] Architecture: blackwell
🏗️  [ARCH] CUDA Tag: cu124
🏗️  [ARCH] Constraints: constraints_blackwell.txt
```

## 📦 Directory Structure

```
├── Dockerfile                    # Universal base image
├── entrypoint.sh                # Smart GPU detection & setup
├── constraints/                 # Architecture-specific packages
│   ├── constraints_ada.txt      # RTX 4090 optimized
│   ├── constraints_hopper.txt   # H100 optimized
│   └── constraints_blackwell.txt# RTX 5090/B200 optimized
├── smoke_test.py               # Comprehensive test suite
└── build.sh                   # Build script
```

## 🧪 Testing

### Run Smoke Tests
```bash
# Test your specific GPU
docker run --rm --gpus all -v /tmp/test:/mnt/netdrive comfyui-universal:latest python3 /smoke_test.py

# Example output
🧪 Starting Universal ComfyUI Smoke Tests...
🎯 Detected Architecture: blackwell
🎮 GPU: NVIDIA GeForce RTX 5090
🔍 Running test_pytorch_basic...
  ✅ pytorch_basic: PASS
🔍 Running test_xformers...
  ✅ xformers: PASS
📊 Test Summary:
  ✅ Passed: 6
  ❌ Failed: 0
  ⏭️ Skipped: 0
```

## ⚙️ Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COMFYUI_HOST` | 0.0.0.0 | ComfyUI bind address |
| `COMFYUI_PORT` | 8188 | ComfyUI port |
| `JUPYTER_PORT` | 8888 | Jupyter Lab port |
| `ENABLE_JUPYTER` | true | Enable Jupyter Lab |
| `PYTHON_VERSION` | 3.11 | Python version to use |
| `SKIP_XFORMERS` | 0 | Skip xFormers installation |

## 🔬 Advanced Usage

### Custom Build
```bash
# Build with specific Python version
PYTHON_VERSION=3.12 ./build.sh

# Build with custom image name
IMAGE_NAME=my-comfyui TAG=v1.0 ./build.sh

# Build and test
RUN_TESTS=true ./build.sh
```

### Development Mode
```bash
# Mount local ComfyUI for development
docker run --gpus all -p 8188:8188 \
  -v /your/comfyui:/mnt/netdrive/comfyui \
  -v /your/models:/mnt/netdrive/models \
  comfyui-universal:latest
```

### Multi-GPU Setup
```bash
# Use all GPUs
docker run --gpus all -p 8188:8188 \
  --ipc=host --shm-size=16g \
  -v /your/data:/mnt/netdrive \
  comfyui-universal:latest

# Use specific GPUs
docker run --gpus '"device=0,1"' -p 8188:8188 \
  -v /your/data:/mnt/netdrive \
  comfyui-universal:latest
```

## 🐛 Troubleshooting

### Check GPU Detection
```bash
# View startup logs
docker logs <container_id>

# Look for architecture detection:
🎯 [GPU] Detected: NVIDIA GeForce RTX 5090
⚡ [ARCH] Blackwell detected (RTX 5090/B200 class)
```

### Performance Issues
```bash
# Check if tensor cores are available
docker exec <container_id> python3 -c "
import torch
print('Tensor Cores:', torch.cuda.get_device_capability()[0] >= 7)
print('Mixed Precision:', torch.cuda.amp.is_available())
"
```

### Memory Issues
```bash
# Monitor GPU memory
docker exec <container_id> nvidia-smi

# Check PyTorch memory allocation
docker exec <container_id> python3 -c "
import torch
print('Allocated:', torch.cuda.memory_allocated() // 1024**2, 'MB')
print('Cached:', torch.cuda.memory_reserved() // 1024**2, 'MB')
"
```

## 📚 Architecture Details

### Ada Lovelace (RTX 4090)
- **PyTorch**: 2.4.0+cu121
- **xFormers**: 0.0.27.post2
- **Features**: Tensor cores, mixed precision, optimized attention

### Hopper (H100)
- **PyTorch**: 2.5.0+cu121  
- **xFormers**: 0.0.28.post1
- **Features**: Advanced tensor cores, flash attention, multi-GPU NCCL

### Blackwell (RTX 5090/B200)
- **PyTorch**: 2.6.0.dev+cu124
- **xFormers**: 0.0.29.dev
- **Features**: Latest optimizations, experimental features, PTX fallback

## 🔒 Security

- Runs as non-root user in production
- Virtual environments isolated per architecture
- No system packages in runtime environment
- Secure token handling for private repositories

## 📈 Performance Tips

1. **Use --ipc=host --shm-size=16g** for multi-GPU setups
2. **Mount persistent volumes** for models and cache
3. **Enable mixed precision** for supported models
4. **Use tensor cores** when available (CC >= 7.0)
5. **Keep compute cache** in persistent storage

## 🤝 Contributing

1. Test on your GPU architecture
2. Update constraints files for new library versions
3. Add smoke tests for new features
4. Submit PR with test results

## 📄 License

MIT License - see LICENSE file for details