import json
import asyncio
from pathlib import Path
import subprocess
import datetime
import os
import shutil

# เพิ่ม concurrency limit เพื่อไม่ให้ใช้ resources มากเกินไป
MAX_CONCURRENT_CLONES = 6  # ลดลงเพื่อความเสถียร
MAX_CONCURRENT_INSTALLS = 3  # ลดลงเพื่อป้องกัน timeout

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
            # NO TIMEOUT - Let git clone complete regardless of time
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
        await asyncio.sleep(3)  # เพิ่ม delay
    return False

async def install_requirements_single(req_path, venv_path, max_retries=2):
    """Install single requirements file with proper venv path"""
    for attempt in range(1, max_retries + 1):
        try:
            print(f"[REQ] Installing {req_path} (attempt {attempt})")
            start = datetime.datetime.now()
            
            # ตรวจสอบขนาดไฟล์
            if req_path.stat().st_size == 0:
                print(f"[SKIP] Empty requirements file: {req_path}")
                return True
            
            # Use correct Python executable
            pybin = venv_path / "bin" / "python"
            pipbin = venv_path / "bin" / "pip"
            
            if not pybin.exists():
                print(f"[ERROR] Python not found: {pybin}")
                return False

            # Create constraints to prevent torch overrides
            constraints_path = "/tmp/constraints_custom_nodes.txt"
            try:
                # Get current torch version to prevent downgrades
                proc = await asyncio.create_subprocess_exec(
                    str(pybin), "-c", "import torch; print(torch.__version__)",
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
                )
                stdout, stderr = await proc.communicate()
                if proc.returncode == 0:
                    torch_ver = stdout.decode().strip()
                    with open(constraints_path, "w") as cf:
                        cf.write(f"torch=={torch_ver}\n")
                        cf.write(f"torchvision\n")  # Allow torchvision to float
                        cf.write(f"torchaudio\n")   # Allow torchaudio to float
                else:
                    constraints_path = None
            except Exception as e:
                print(f"[DEBUG] Could not get torch version: {e}")
                constraints_path = None

            # Prepare install command
            args = [str(pipbin), "install", "--no-cache-dir"]
            if constraints_path and os.path.exists(constraints_path):
                args.extend(["--constraint", constraints_path])
            args.extend(["-r", str(req_path)])

            # Run installation - NO TIMEOUT for slow internet
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE, 
                stderr=asyncio.subprocess.PIPE
            )
            
            # NO TIMEOUT - Let pip install complete regardless of time
            stdout, stderr = await proc.communicate()
            end = datetime.datetime.now()
            print(f"[DEBUG] Installation completed at {end} (took {(end-start).total_seconds():.1f}s)")
            
            if proc.returncode == 0:
                print(f"[REQ] Success: {req_path}")
                return True
            else:
                print(f"[REQ] Failed: {req_path} (attempt {attempt})")
                print(f"[ERROR] {stderr.decode()}")
                
        except Exception as e:
            print(f"[REQ] Exception for {req_path} (attempt {attempt}): {e}")
        
        await asyncio.sleep(5)  # เพิ่ม delay
    return False

async def install_requirements_parallel(base_dir, venv_path):
    """Install requirements files in parallel with concurrency limit"""
    reqs = list(base_dir.glob("*/requirements.txt"))
    reqs = [r for r in reqs if r.exists() and r.stat().st_size > 0]  # ข้ามไฟล์ว่าง
    
    if not reqs:
        print("[REQ] No requirements.txt files found")
        return
    
    print(f"[REQ] Found {len(reqs)} requirements files to install")
    
    # ใช้ semaphore เพื่อจำกัด concurrency
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_INSTALLS)
    
    async def install_with_semaphore(req):
        async with semaphore:
            return await install_requirements_single(req, venv_path)
    
    # รัน parallel installation
    tasks = [install_with_semaphore(req) for req in reqs]
    results = await asyncio.gather(*tasks, return_exceptions=True)
    
    success_count = sum(1 for r in results if r is True)
    print(f"[REQ] Completed: {success_count}/{len(reqs)} successful installations")

async def main():
    base_dir = Path("/mnt/netdrive/comfyui/custom_nodes")
    base_dir.mkdir(parents=True, exist_ok=True)
    
    # Get venv path from environment variable set by entrypoint
    venv_path = Path(os.environ.get("VENV_PATH", "/mnt/netdrive/python_envs/unknown"))
    if not venv_path.exists():
        print(f"[ERROR] Virtual environment not found: {venv_path}")
        return
    
    print(f"[INFO] Using virtual environment: {venv_path}")
    
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
        print("[SETUP] All custom nodes already exist. Proceeding to requirements installation.")
    else:
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
    await install_requirements_parallel(base_dir, venv_path)

if __name__ == "__main__":
    asyncio.run(main())