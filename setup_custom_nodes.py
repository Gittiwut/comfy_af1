import json
import asyncio
from pathlib import Path
import subprocess
import datetime
import os
import shutil

# เพิ่ม concurrency limit เพื่อไม่ให้ใช้ resources มากเกินไป
MAX_CONCURRENT_CLONES = 8
MAX_CONCURRENT_INSTALLS = 4

async def clone_repo(name, repo, base_dir, max_retries=3):
    dest = base_dir / name
    if dest.exists():
        print(f"[SKIP] {name} already exists.")
        return True
    print(f"[CLONE] {repo} -> {dest}")
    for attempt in range(1, max_retries + 1):
        try:
            start = datetime.datetime.now()
            proc = await asyncio.create_subprocess_exec(
                "git", "clone", "--depth=1", "--single-branch", repo, str(dest),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await proc.communicate()
            end = datetime.datetime.now()
            print(f"[CLONE] {name} attempt {attempt} took {(end-start).total_seconds():.1f}s")
            if proc.returncode == 0:
                print(f"[CLONE] Success: {name}")
                return True
            else:
                print(f"[CLONE] Failed: {name} (attempt {attempt})\n{stderr.decode()}")
                # ลบ directory ที่ clone ไม่สำเร็จ
                if dest.exists():
                    shutil.rmtree(dest, ignore_errors=True)
        except Exception as e:
            print(f"[CLONE] Exception for {name} (attempt {attempt}): {e}")
            if dest.exists():
                shutil.rmtree(dest, ignore_errors=True)
        await asyncio.sleep(2)
    return False

async def install_requirements_single(req_path, max_retries=2):
    """Install single requirements file"""
    for attempt in range(1, max_retries + 1):
        try:
            print(f"[REQ] Installing {req_path} (attempt {attempt})")
            start = datetime.datetime.now()
            print(f"[DEBUG] Starting installation at {start}")
            print(f"[DEBUG] File size: {req_path.stat().st_size} bytes")
            print(f"[DEBUG] Installing requirements from: {req_path}")
            # เพิ่ม Network Check
            import socket
            try:
                socket.create_connection(("8.8.8.8", 53), timeout=3)
                print(f"[DEBUG] Network connectivity: OK")
            except Exception as e:
                print(f"[DEBUG] Network connectivity: SLOW ({e})")

            # Run install without a hard timeout to avoid aborting long installs
            # Use constraints to prevent torch/xformers from being changed by custom node requirements
            constraints_path = "/tmp/constraints_custom_nodes.txt"
            try:
                torch_ver = os.environ.get("TORCH_VER", "2.8.0")
                cu_tag = os.environ.get("CU_TAG", "cpu")
                with open(constraints_path, "w") as cf:
                    cf.write(f"torch=={torch_ver}+{cu_tag}\n")
                    # torchvision is often pulled transitively
                    # NOTE: TVISION_VER is not exported here; rely on torch pin; torchvision resolves accordingly
                extra_index = []
                if cu_tag != "cpu":
                    extra_index = ["--extra-index-url", f"https://download.pytorch.org/whl/{cu_tag}"]
            except Exception:
                constraints_path = None
                extra_index = []

            args = [
                "uv", "pip", "install",
                "--python=/mnt/netdrive/python_env/bin/python",
                "--no-cache",
            ]
            if constraints_path:
                args += ["--constraint", constraints_path]
            args += extra_index + ["-r", str(req_path)]

            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            
            stdout, stderr = await proc.communicate()
            end = datetime.datetime.now()
            print(f"[DEBUG] Installation completed at {end} (took {(end-start).total_seconds():.1f}s)")
            
            if proc.returncode == 0:
                print(f"[REQ] Success: {req_path}")
                return True
            else:
                print(f"[REQ] Failed: {req_path} (attempt {attempt})\n{stderr.decode()}")
        except asyncio.TimeoutError:
            print(f"[REQ] Timeout for {req_path} (attempt {attempt})")
        except Exception as e:
            print(f"[REQ] Exception for {req_path} (attempt {attempt}): {e}")
        await asyncio.sleep(2)
    return False

async def install_requirements_parallel(base_dir):
    """Install requirements files in parallel with concurrency limit"""
    reqs = list(base_dir.glob("*/requirements.txt"))
    reqs = [r for r in reqs if r.stat().st_size > 0]  # <== ข้ามไฟล์ว่าง
    if not reqs:
        print("[REQ] No requirements.txt files found")
        return
    
    # ใช้ semaphore เพื่อจำกัด concurrency
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_INSTALLS)
    
    async def install_with_semaphore(req):
        async with semaphore:
            return await install_requirements_single(req)
    
    # รัน parallel installation
    tasks = [install_with_semaphore(req) for req in reqs]
    results = await asyncio.gather(*tasks, return_exceptions=True)
    
    success_count = sum(1 for r in results if r is True)
    print(f"[REQ] Completed: {success_count}/{len(reqs)} successful installations")

async def main():
    base_dir = Path("/mnt/netdrive/comfyui/custom_nodes")
    base_dir.mkdir(parents=True, exist_ok=True)
    with open("/custom_nodes_list.json") as f:
        nodes = json.load(f)
    # สร้าง clone tasks
    clone_tasks = []
    for name, repos in nodes.items():
        for repo in repos:
            dest = base_dir / name
            if not dest.exists():
                clone_tasks.append(clone_repo(name, repo, base_dir))
    if not clone_tasks:
        print("[SETUP] All custom nodes already exist. Exiting.")
        return
    
    # ใช้ semaphore เพื่อจำกัด concurrency
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_CLONES)
    
    async def clone_with_semaphore(task):
        async with semaphore:
            return await task
    
    # รัน parallel cloning
    print(f"[SETUP] Starting parallel clone of {len(clone_tasks)} repositories...")
    clone_results = await asyncio.gather(*[clone_with_semaphore(task) for task in clone_tasks], return_exceptions=True)
    
    success_count = sum(1 for r in clone_results if r is True)
    print(f"[SETUP] Clone completed: {success_count}/{len(clone_tasks)} successful")
    
    # รัน parallel requirements installation
    print("[SETUP] Starting parallel requirements installation...")
    await install_requirements_parallel(base_dir)

if __name__ == "__main__":
    asyncio.run(main()) 