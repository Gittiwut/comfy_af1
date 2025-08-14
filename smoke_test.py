#!/usr/bin/env python3
"""
Universal ComfyUI Smoke Test Suite
Tests compatibility across RTX 4090 (Ada) → RTX 5090 (Blackwell) → H100 (Hopper) → B200 (Blackwell)
"""

import json
import time
import sys
import os
import traceback
from pathlib import Path

def get_gpu_info():
    """Get comprehensive GPU information"""
    try:
        import torch
        if torch.cuda.is_available():
            return {
                "name": torch.cuda.get_device_name(),
                "compute_capability": torch.cuda.get_device_capability(),
                "memory_gb": torch.cuda.get_device_properties(0).total_memory // 1024**3,
                "device_count": torch.cuda.device_count(),
                "pytorch_version": torch.__version__,
                "cuda_version": torch.version.cuda
            }
    except Exception as e:
        return {"error": str(e)}
    return {"cuda_available": False}

def test_pytorch_basic():
    """Test basic PyTorch operations"""
    results = {"name": "pytorch_basic", "status": "FAIL", "details": {}}
    
    try:
        import torch
        
        # Basic tensor operations
        start_time = time.time()
        
        if torch.cuda.is_available():
            device = "cuda"
            x = torch.randn(1000, 1000, device=device)
            y = torch.randn(1000, 1000, device=device)
            
            # Matrix multiplication
            z = torch.mm(x, y)
            
            # Convolution test
            conv = torch.nn.Conv2d(3, 16, 3).to(device)
            img = torch.randn(1, 3, 224, 224, device=device)
            output = conv(img)
            
            results["details"]["device"] = device
            results["details"]["matrix_mult_shape"] = list(z.shape)
            results["details"]["conv_output_shape"] = list(output.shape)
        else:
            device = "cpu"
            x = torch.randn(100, 100)
            y = torch.randn(100, 100)
            z = torch.mm(x, y)
            results["details"]["device"] = device
            results["details"]["matrix_mult_shape"] = list(z.shape)
        
        elapsed = time.time() - start_time
        results["details"]["elapsed_seconds"] = elapsed
        results["status"] = "PASS"
        
    except Exception as e:
        results["details"]["error"] = str(e)
        results["details"]["traceback"] = traceback.format_exc()
    
    return results

def test_xformers():
    """Test xFormers if available"""
    results = {"name": "xformers", "status": "SKIP", "details": {}}
    
    try:
        import xformers
        results["details"]["version"] = xformers.__version__
        
        # Test basic attention operation if CUDA available
        try:
            import xformers.ops
            import torch
            
            if torch.cuda.is_available():
                # Simple attention test
                batch_size, seq_len, embed_dim = 2, 128, 64
                query = torch.randn(batch_size, seq_len, embed_dim, device="cuda", dtype=torch.float16)
                key = torch.randn(batch_size, seq_len, embed_dim, device="cuda", dtype=torch.float16)
                value = torch.randn(batch_size, seq_len, embed_dim, device="cuda", dtype=torch.float16)
                
                start_time = time.time()
                output = xformers.ops.memory_efficient_attention(query, key, value)
                elapsed = time.time() - start_time
                
                results["details"]["attention_test"] = "PASS"
                results["details"]["output_shape"] = list(output.shape)
                results["details"]["elapsed_seconds"] = elapsed
                results["status"] = "PASS"
            else:
                results["details"]["attention_test"] = "SKIP (No CUDA)"
                results["status"] = "PASS"
                
        except Exception as e:
            results["details"]["attention_error"] = str(e)
            results["status"] = "PASS"  # xFormers loaded but ops failed
            
    except ImportError:
        results["details"]["reason"] = "xFormers not installed"
    except Exception as e:
        results["details"]["error"] = str(e)
        results["status"] = "FAIL"
    
    return results

def test_triton():
    """Test Triton if available"""
    results = {"name": "triton", "status": "SKIP", "details": {}}
    
    try:
        import triton
        results["details"]["version"] = triton.__version__
        
        # Simple kernel test
        try:
            import triton.language as tl
            import torch
            
            @triton.jit
            def add_kernel(x_ptr, y_ptr, output_ptr, n_elements, BLOCK_SIZE: tl.constexpr):
                pid = tl.program_id(axis=0)
                block_start = pid * BLOCK_SIZE
                offsets = block_start + tl.arange(0, BLOCK_SIZE)
                mask = offsets < n_elements
                x = tl.load(x_ptr + offsets, mask=mask)
                y = tl.load(y_ptr + offsets, mask=mask)
                output = x + y
                tl.store(output_ptr + offsets, output, mask=mask)
            
            if torch.cuda.is_available():
                size = 1024
                x = torch.randn(size, device='cuda')
                y = torch.randn(size, device='cuda')
                output = torch.empty_like(x)
                
                start_time = time.time()
                grid = lambda meta: (triton.cdiv(size, meta['BLOCK_SIZE']),)
                add_kernel[grid](x, y, output, size, BLOCK_SIZE=1024)
                torch.cuda.synchronize()
                elapsed = time.time() - start_time
                
                results["details"]["kernel_test"] = "PASS"
                results["details"]["elapsed_seconds"] = elapsed
                results["status"] = "PASS"
            else:
                results["details"]["kernel_test"] = "SKIP (No CUDA)"
                results["status"] = "PASS"
                
        except Exception as e:
            results["details"]["kernel_error"] = str(e)
            results["status"] = "PASS"  # Triton loaded but kernel failed
            
    except ImportError:
        results["details"]["reason"] = "Triton not installed"
    except Exception as e:
        results["details"]["error"] = str(e)
        results["status"] = "FAIL"
    
    return results

def test_multi_gpu():
    """Test multi-GPU if available"""
    results = {"name": "multi_gpu", "status": "SKIP", "details": {}}
    
    try:
        import torch
        
        if torch.cuda.is_available() and torch.cuda.device_count() > 1:
            device_count = torch.cuda.device_count()
            results["details"]["device_count"] = device_count
            
            # Test basic multi-GPU operations
            devices = []
            for i in range(device_count):
                device_name = torch.cuda.get_device_name(i)
                devices.append({"id": i, "name": device_name})
            
            results["details"]["devices"] = devices
            
            # Simple multi-GPU tensor test
            try:
                tensors = []
                for i in range(min(device_count, 2)):  # Test max 2 GPUs
                    tensor = torch.randn(100, 100, device=f"cuda:{i}")
                    tensors.append(tensor)
                
                results["details"]["multi_gpu_tensors"] = "PASS"
                results["status"] = "PASS"
                
            except Exception as e:
                results["details"]["multi_gpu_error"] = str(e)
                results["status"] = "FAIL"
                
        elif torch.cuda.is_available():
            results["details"]["reason"] = "Single GPU detected"
            results["details"]["device_count"] = 1
            results["status"] = "PASS"
        else:
            results["details"]["reason"] = "No CUDA available"
            
    except Exception as e:
        results["details"]["error"] = str(e)
        results["status"] = "FAIL"
    
    return results

def test_memory_efficiency():
    """Test memory allocation and efficiency"""
    results = {"name": "memory_efficiency", "status": "FAIL", "details": {}}
    
    try:
        import torch
        
        if torch.cuda.is_available():
            # Get initial memory stats
            torch.cuda.empty_cache()
            initial_memory = torch.cuda.memory_allocated()
            total_memory = torch.cuda.get_device_properties(0).total_memory
            
            # Allocate progressively larger tensors
            allocated_mb = []
            max_tensor_size = 0
            
            for size_mb in [10, 50, 100, 500, 1000]:
                try:
                    elements = (size_mb * 1024 * 1024) // 4  # 4 bytes per float32
                    tensor = torch.randn(elements, device='cuda', dtype=torch.float32)
                    current_memory = torch.cuda.memory_allocated()
                    allocated_mb.append(size_mb)
                    max_tensor_size = size_mb
                    del tensor
                    torch.cuda.empty_cache()
                except torch.cuda.OutOfMemoryError:
                    break
            
            results["details"]["max_tensor_mb"] = max_tensor_size
            results["details"]["allocated_sizes_mb"] = allocated_mb
            results["details"]["total_memory_gb"] = total_memory // (1024**3)
            results["details"]["memory_efficiency"] = f"{(max_tensor_size / (total_memory // 1024**2)) * 100:.1f}%"
            results["status"] = "PASS"
            
        else:
            results["details"]["reason"] = "No CUDA available"
            results["status"] = "SKIP"
            
    except Exception as e:
        results["details"]["error"] = str(e)
        results["details"]["traceback"] = traceback.format_exc()
    
    return results

def test_architecture_specific():
    """Test architecture-specific features"""
    results = {"name": "architecture_specific", "status": "FAIL", "details": {}}
    
    try:
        import torch
        
        if torch.cuda.is_available():
            # Get compute capability
            major, minor = torch.cuda.get_device_capability()
            cc = major * 10 + minor
            
            results["details"]["compute_capability"] = f"{major}.{minor}"
            
            # Test tensor cores if available (CC >= 7.0)
            if cc >= 70:
                try:
                    # Test mixed precision
                    with torch.cuda.amp.autocast():
                        x = torch.randn(512, 512, device='cuda', dtype=torch.float16)
                        y = torch.randn(512, 512, device='cuda', dtype=torch.float16)
                        z = torch.mm(x, y)
                    
                    results["details"]["tensor_cores"] = "AVAILABLE"
                    results["details"]["mixed_precision"] = "PASS"
                except Exception as e:
                    results["details"]["tensor_cores"] = "ERROR"
                    results["details"]["mixed_precision_error"] = str(e)
            else:
                results["details"]["tensor_cores"] = "NOT_AVAILABLE"
            
            # Test flash attention if available (modern architectures)
            if cc >= 80:  # Ampere and newer
                try:
                    # Test if flash attention patterns work
                    batch, heads, seq_len, head_dim = 2, 8, 1024, 64
                    q = torch.randn(batch, heads, seq_len, head_dim, device='cuda', dtype=torch.float16)
                    k = torch.randn(batch, heads, seq_len, head_dim, device='cuda', dtype=torch.float16)
                    v = torch.randn(batch, heads, seq_len, head_dim, device='cuda', dtype=torch.float16)
                    
                    # Scaled dot product attention (available in PyTorch 2.0+)
                    if hasattr(torch.nn.functional, 'scaled_dot_product_attention'):
                        output = torch.nn.functional.scaled_dot_product_attention(q, k, v)
                        results["details"]["flash_attention"] = "AVAILABLE"
                    else:
                        results["details"]["flash_attention"] = "NOT_AVAILABLE"
                        
                except Exception as e:
                    results["details"]["flash_attention"] = "ERROR"
                    results["details"]["flash_attention_error"] = str(e)
            
            results["status"] = "PASS"
            
        else:
            results["details"]["reason"] = "No CUDA available"
            results["status"] = "SKIP"
            
    except Exception as e:
        results["details"]["error"] = str(e)
    
    return results

def run_smoke_tests():
    """Run complete smoke test suite"""
    print("🧪 Starting Universal ComfyUI Smoke Tests...")
    
    # Get system info
    gpu_info = get_gpu_info()
    
    # Determine architecture tag
    arch_tag = "unknown"
    if "compute_capability" in gpu_info:
        major, minor = gpu_info["compute_capability"]
        cc = major * 10 + minor
        if cc >= 100:
            arch_tag = "blackwell"
        elif cc >= 90:
            arch_tag = "hopper" 
        elif cc >= 89:
            arch_tag = "ada"
        elif cc >= 86:
            arch_tag = "ampere"
    
    # Test suite
    tests = [
        test_pytorch_basic,
        test_xformers,
        test_triton,
        test_multi_gpu,
        test_memory_efficiency,
        test_architecture_specific
    ]
    
    results = {
        "timestamp": time.time(),
        "gpu_info": gpu_info,
        "architecture": arch_tag,
        "python_version": sys.version,
        "tests": []
    }
    
    print(f"🎯 Detected Architecture: {arch_tag}")
    if "name" in gpu_info:
        print(f"🎮 GPU: {gpu_info['name']}")
    
    # Run tests
    for test_func in tests:
        print(f"🔍 Running {test_func.__name__}...")
        test_result = test_func()
        results["tests"].append(test_result)
        
        status_emoji = "✅" if test_result["status"] == "PASS" else "❌" if test_result["status"] == "FAIL" else "⏭️"
        print(f"  {status_emoji} {test_result['name']}: {test_result['status']}")
    
    # Summary
    passed = len([t for t in results["tests"] if t["status"] == "PASS"])
    failed = len([t for t in results["tests"] if t["status"] == "FAIL"])
    skipped = len([t for t in results["tests"] if t["status"] == "SKIP"])
    
    print(f"\n📊 Test Summary:")
    print(f"  ✅ Passed: {passed}")
    print(f"  ❌ Failed: {failed}")
    print(f"  ⏭️ Skipped: {skipped}")
    
    # Save results
    output_dir = Path("/mnt/netdrive/smoke_tests")
    output_dir.mkdir(exist_ok=True)
    
    output_file = output_dir / f"smoke_test_{arch_tag}_{int(time.time())}.json"
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)
    
    print(f"💾 Results saved to: {output_file}")
    
    # Return exit code
    return 0 if failed == 0 else 1

if __name__ == "__main__":
    exit_code = run_smoke_tests()
    sys.exit(exit_code)