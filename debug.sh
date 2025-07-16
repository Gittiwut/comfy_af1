#!/bin/bash

# Debug script for RunPod issues

echo "=== ComfyUI RunPod Debugging ==="
echo ""

# Check if ComfyUI is running
echo "1. Checking ComfyUI process..."
ps aux | grep -E "python.*main.py" | grep -v grep

# Check if JupyterLab is running
echo ""
echo "2. Checking JupyterLab process..."
ps aux | grep -E "jupyter.*lab" | grep -v grep

# Check ports
echo ""
echo "3. Checking open ports..."
netstat -tlnp 2>/dev/null | grep -E "8188|8888" || ss -tlnp | grep -E "8188|8888"

# Check logs
echo ""
echo "4. ComfyUI logs (last 20 lines):"
tail -n 20 /mnt/netdrive/comfyui.log 2>/dev/null || echo "No ComfyUI logs found"

echo ""
echo "5. JupyterLab logs (last 20 lines):"
tail -n 20 /mnt/netdrive/jupyter.log 2>/dev/null || echo "No Jupyter logs found"

# Check directory structure
echo ""
echo "6. ComfyUI directory structure:"
ls -la /mnt/netdrive/comfyui/ 2>/dev/null || echo "ComfyUI directory not found"

# Check Python packages
echo ""
echo "7. Key Python packages:"
python3 -c "
import pkg_resources
packages = ['torch', 'jupyterlab', 'aiohttp', 'numpy', 'pillow']
for pkg in packages:
    try:
        version = pkg_resources.get_distribution(pkg).version
        print(f'✅ {pkg}: {version}')
    except:
        print(f'❌ {pkg}: NOT INSTALLED')
"

# Network connectivity
echo ""
echo "8. Network connectivity:"
curl -s -o /dev/null -w "GitHub: %{http_code}\n" https://github.com
curl -s -o /dev/null -w "PyPI: %{http_code}\n" https://pypi.org

echo ""
echo "=== End of debugging info ==="
