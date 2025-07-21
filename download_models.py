import os
import json
import asyncio
from pathlib import Path
import shutil
import tempfile
import aiohttp
import aiofiles

# เพิ่ม concurrency limit
MAX_CONCURRENT_DOWNLOADS = 8

def check_aria2c():
    if shutil.which("aria2c") is None:
        print("[ERROR] aria2c not found! Please install aria2c for fast downloads.")
        print("[INFO] Will use aiohttp fallback for downloads.")
        return False
    print("[INFO] aria2c found.")
    return True

# Ensure TMPDIR is set to a directory with enough space
TMPDIR = os.environ.get("TMPDIR", "/mnt/netdrive/tmp")
os.makedirs(TMPDIR, exist_ok=True)
os.environ["TMPDIR"] = TMPDIR

async def download_with_aria2c(url, dest_dir):
    filename = url.split("/")[-1]
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / filename
    if dest.exists():
        print(f"[SKIP] {dest} already exists.")
        return True
    print(f"[MODEL] Downloading: {url} -> {dest}")
    try:
        proc = await asyncio.create_subprocess_exec(
            "aria2c", "-c", "-x", "4", "-s", "4", url, "-d", str(dest_dir), "-o", filename,
            "--dir", str(dest_dir),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "TMPDIR": TMPDIR}
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode == 0:
            print(f"[MODEL] Downloaded: {dest}")
            return True
        else:
            print(f"[ERROR] aria2c failed for {url}, fallback to aiohttp. Reason: {stderr.decode()}")
            return await download_with_aiohttp(url, dest)
    except FileNotFoundError:
        print(f"[ERROR] aria2c not found, using aiohttp fallback for {url}")
        return await download_with_aiohttp(url, dest)
    except Exception as e:
        print(f"[ERROR] aria2c error for {url}: {e}, using aiohttp fallback")
        return await download_with_aiohttp(url, dest)

async def download_with_aiohttp(url, dest):
    """Download using aiohttp for better performance"""
    try:
        print(f"[MODEL] (aiohttp) Downloading: {url} -> {dest}")
        timeout = aiohttp.ClientTimeout(total=300)  # 5 minutes timeout
        connector = aiohttp.TCPConnector(limit=100, limit_per_host=10)
        async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
            async with session.get(url) as response:
                if response.status == 200:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    async with aiofiles.open(dest, 'wb') as f:
                        async for chunk in response.content.iter_chunked(16384):
                            await f.write(chunk)
                    print(f"[MODEL] Downloaded: {dest}")
                    return True
                else:
                    print(f"[ERROR] HTTP {response.status} for {url}")
                    return False
    except Exception as e:
        print(f"[ERROR] Failed to download {url}: {e}")
        return False

async def download_models_parallel(config, base_dir):
    """Download models in parallel with concurrency limit"""
    aria2c_available = check_aria2c()
    download_tasks = []
    for category, urls in config.items():
        cat_dir = base_dir / category
        for url in urls:
            if aria2c_available:
                download_tasks.append(download_with_aria2c(url, cat_dir))
            else:
                filename = url.split("/")[-1]
                dest = cat_dir / filename
                download_tasks.append(download_with_aiohttp(url, dest))
    
    # ใช้ semaphore เพื่อจำกัด concurrency
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)
    
    async def download_with_semaphore(task):
        async with semaphore:
            return await task
    
    # รัน parallel downloads
    print(f"[DOWNLOAD] Starting parallel download of {len(download_tasks)} models...")
    results = await asyncio.gather(*[download_with_semaphore(task) for task in download_tasks], return_exceptions=True)
    
    success_count = sum(1 for r in results if r is True)
    print(f"[DOWNLOAD] Download completed: {success_count}/{len(download_tasks)} successful")

async def main():
    config_path = "/models_config.json"
    base_dir = Path("/mnt/netdrive/comfyui/models")
    
    with open(config_path) as f:
        config = json.load(f)
    
    await download_models_parallel(config, base_dir)

if __name__ == "__main__":
    asyncio.run(main())