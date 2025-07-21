#!/usr/bin/env python3
"""
ComfyUI Auto-Install Wrapper
Automatically installs missing modules and restarts ComfyUI
"""
import sys
import subprocess
import re
import importlib
import os
import signal
import time
import threading

# List of optional modules that can be auto-installed
OPTIONAL_MODULES = [
    # Core dependencies (backup)
    "aiohttp",
    "requests",
    "psutil",
    "scipy",
    "comfyui-frontend-package",
    
    # Optional modules
    "torchsde",
    "omegaconf",
    "accelerate",
    "diffusers",
    "controlnet_aux",
    "opencv-python",
    "mediapipe",
    "ultralytics",
    "insightface",
    "basicsr",
    "facexlib",
    "gfpgan",
    "realesrgan",
    "codeformer",
    "clip",
    "open_clip_torch",
    "timm",
    "kornia",
    "albumentations",
    "imageio",
    "imageio-ffmpeg",
    "av",
    "moviepy",
    "pytorch_lightning",
    "wandb",
    "tensorboard",
    "tensorboardX",
    "onnxruntime",
    "onnxruntime-gpu",
    "comfyui_controlnet_aux",
    "comfyui_ultralytics",
    "comfyui_insightface",
    "comfyui_face_restoration",
    "comfyui_anime_segmentation",
    "comfyui_face_detection",
    "comfyui_face_parsing",
    "comfyui_face_landmark",
    "comfyui_face_swap",
    "comfyui_face_enhancement"
]

def install_module(module_name):
    """Install module using uv"""
    try:
        print(f"[AUTO-INSTALL] Installing {module_name}...")
        result = subprocess.run([
            "uv", "pip", "install",
            "--python=/mnt/netdrive/python_env/bin/python",
            "--no-cache", module_name
        ], capture_output=True, text=True)
        
        if result.returncode == 0:
            print(f"[SUCCESS] Installed {module_name}")
            return True
        else:
            print(f"[FAILED] Failed to install {module_name}: {result.stderr}")
            return False
    except Exception as e:
        print(f"[ERROR] Exception installing {module_name}: {e}")
        return False

def detect_missing_module(error_msg):
    """Detect missing module from error message"""
    match = re.search(r"No module named '([^']+)'", error_msg)
    if match:
        return match.group(1)
    return None

def auto_install_missing(error_msg):
    """Auto-install missing module if it's in our list"""
    missing_module = detect_missing_module(error_msg)
    if missing_module:
        print(f"[AUTO-INSTALL] Detected missing module: {missing_module}")
        
        # Check if it's in our optional modules list
        if missing_module in OPTIONAL_MODULES:
            if install_module(missing_module):
                print(f"[AUTO-INSTALL] Successfully installed {missing_module}")
                return True
            else:
                print(f"[AUTO-INSTALL] Failed to install {missing_module}")
                return False
        else:
            print(f"[AUTO-INSTALL] {missing_module} not in optional list")
            return False
    return False

def run_comfyui_with_retry(args, max_retries=3):
    """Run ComfyUI with automatic retry on missing modules"""
    retry_count = 0
    
    while retry_count < max_retries:
        try:
            print(f"[WRAPPER] Starting ComfyUI (attempt {retry_count + 1}/{max_retries})")
            print(f"[WRAPPER] Arguments: {args}")
            print(f"[WRAPPER] Working directory: {os.getcwd()}")
            
            # Start ComfyUI process
            process = subprocess.Popen(
                ["python3", "main.py"] + args,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1
            )
            
            print("[WRAPPER] ComfyUI process started, monitoring output...")
            
            # Monitor output for missing module errors and progress
            line_count = 0
            start_time = time.time()
            startup_complete = False
            
            while True:
                line = process.stdout.readline()
                if not line:
                    break
                
                line_count += 1
                elapsed = time.time() - start_time
                
                # Print progress every 20 lines or 60 seconds (ลดความถี่)
                if line_count % 20 == 0 or elapsed > 60:
                    print(f"[WRAPPER] Progress: {line_count} lines, {elapsed:.1f}s elapsed")
                
                print(line.rstrip())
                
                # Check for startup completion indicators (เพิ่ม indicators)
                if any(indicator in line for indicator in [
                    "Starting server", "Server started", "Serving on", 
                    "ComfyUI startup time", "Total VRAM", "Device: cuda"
                ]):
                    if not startup_complete:
                        print(f"[WRAPPER] ✅ ComfyUI server started successfully after {elapsed:.1f}s")
                        startup_complete = True
                
                # Check for missing module error
                if "No module named" in line:
                    print(f"[WRAPPER] ❌ Detected missing module error after {elapsed:.1f}s")
                    process.terminate()
                    process.wait()
                    
                    if auto_install_missing(line):
                        print("[WRAPPER] Module installed, retrying ComfyUI...")
                        retry_count += 1
                        time.sleep(2)  # Wait a bit before retry
                        break
                    else:
                        print("[WRAPPER] Failed to install module, exiting")
                        return False
            
            # If we get here, ComfyUI is running successfully
            total_time = time.time() - start_time
            print(f"[WRAPPER] ✅ ComfyUI started successfully after {total_time:.1f}s")
            process.wait()
            return True
            
        except KeyboardInterrupt:
            print("[WRAPPER] Received interrupt signal")
            if 'process' in locals():
                process.terminate()
            return True
        except Exception as e:
            print(f"[WRAPPER] Exception: {e}")
            retry_count += 1
            if retry_count >= max_retries:
                print("[WRAPPER] Max retries reached, exiting")
                return False
            time.sleep(2)
    
    return False

if __name__ == "__main__":
    # Get ComfyUI arguments
    comfyui_args = sys.argv[1:] if len(sys.argv) > 1 else []
    
    print("[WRAPPER] ComfyUI Auto-Install Wrapper")
    print(f"[WRAPPER] Arguments: {comfyui_args}")
    
    # Run ComfyUI with auto-install capability
    success = run_comfyui_with_retry(comfyui_args)
    
    if not success:
        print("[WRAPPER] Failed to start ComfyUI")
        sys.exit(1)
    else:
        print("[WRAPPER] ComfyUI wrapper completed") 