import os
import json
import asyncio
from pathlib import Path
import shutil
import time
import aiohttp
import aiofiles
from urllib.parse import urlparse
import re

# เพิ่ม concurrency limit
MAX_CONCURRENT_DOWNLOADS = 8

CIVITAI_TOKEN = os.environ.get("CIVITAI_TOKEN")

class DownloadProgress:
    def __init__(self, total_downloads):
        self.total = total_downloads
        self.completed = 0
        self.failed = 0
        self.start_time = time.time()
    
    def update(self, success=True):
        if success:
            self.completed += 1
        else:
            self.failed += 1
    
    def get_progress(self):
        elapsed = time.time() - self.start_time
        progress = (self.completed + self.failed) / self.total * 100
        return f"[{self.completed}/{self.total}] ({progress:.1f}%) - {elapsed:.1f}s"

def get_filename_from_url(url):
    """Get filename from URL with better handling for Civitai URLs"""
    path = urlparse(url).path
    filename = os.path.basename(path)

    # For Civitai URLs, we'll let Content-Disposition handle the filename
    if "civitai.com" in url:
        if "models/" in url:
            model_id = url.split("models/")[1].split("?")[0]
            # Use a temporary name that will be overridden by Content-Disposition
            filename = f"temp_model_{model_id}.safetensors"
    
    return filename

def check_aria2c():
    if shutil.which("aria2c") is None:
        print("[INFO] aria2c not found. Using aiohttp for all downloads.")
        return False
    print("[INFO] aria2c found.")
    return True

# Ensure TMPDIR is set to a directory with enough space
TMPDIR = os.environ.get("TMPDIR", "/mnt/netdrive/tmp")
os.makedirs(TMPDIR, exist_ok=True)
os.environ["TMPDIR"] = TMPDIR

async def check_existing_files(config, base_dir):
    """ตรวจสอบไฟล์ที่มีอยู่แล้วใน network volume"""
    existing_files = {}
    for category, urls in config.items():
        cat_dir = base_dir / category
        if cat_dir.exists():
            existing_files[category] = list(cat_dir.glob('*'))
            print(f"[CHECK] Found {len(existing_files[category])} files in {category}")
        else:
            existing_files[category] = []
            print(f"[CHECK] Directory {category} does not exist")
    return existing_files

async def download_with_aria2c(url, dest_dir):
    filename = get_filename_from_url(url)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / filename

    print(f"[MODEL] (aria2c) Downloading: {url}")
    try:
        # For Civitai URLs, use aiohttp instead
        if "civitai.com" in url:
            print(f"[INFO] Using aiohttp for Civitai URL: {url}")
            return await download_with_aiohttp(url, dest)

        # Use aria2c for other URLs
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
            return await download_with_aiohttp(url, dest_dir)
    except FileNotFoundError:
        print(f"[ERROR] aria2c not found, using aiohttp fallback for {url}")
        return await download_with_aiohttp(url, dest_dir)
    except Exception as e:
        print(f"[ERROR] aria2c error for {url}: {e}, using aiohttp fallback")
        return await download_with_aiohttp(url, dest_dir)

async def download_with_aiohttp(url, dest_dir, category=None):
    """Download using aiohttp for better performance"""
    try:
        print(f"[MODEL] (aiohttp) Downloading: {url}")
        # Increase total timeout to handle large model files
        timeout = aiohttp.ClientTimeout(total=None, connect=30, sock_read=None, sock_connect=30)
        connector = aiohttp.TCPConnector(limit=64, limit_per_host=8, enable_cleanup_closed=True)
        headers = {}

        # Add Authorization header for Civitai
        if "civitai.com" in url and CIVITAI_TOKEN:
            headers["Authorization"] = f"Bearer {CIVITAI_TOKEN}"

        async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
            async with session.get(url, headers=headers) as response:
                if response.status == 200:
                    # Get filename from Content-Disposition
                    cd = response.headers.get("Content-Disposition")
                    filename = None
                    if cd:
                        match = re.search(r'filename="(.+)"', cd)
                        if match:
                            filename = match.group(1)
                    
                    # Fallback to URL-based filename
                    if not filename:
                        filename = get_filename_from_url(url)
                    dest = dest_dir / filename
                    
                    # Skip Download for exist file
                    if dest.exists():
                        print(f"[SKIP] {dest} already exists.")
                        return True

                    # Create directory and download
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    temp_dest = dest.with_suffix(dest.suffix + '.tmp')
                    
                    async with aiofiles.open(temp_dest, 'wb') as f:
                        async for chunk in response.content.iter_chunked(16384):
                            await f.write(chunk)
                    
                    # Verify file size and move to final location
                    if temp_dest.exists() and temp_dest.stat().st_size > 0:
                        temp_dest.rename(dest)
                        print(f"[MODEL] Downloaded: {dest}")
                        return True
                    else:
                        print(f"[ERROR] Downloaded file is empty or missing: {temp_dest}")
                        if temp_dest.exists():
                            temp_dest.unlink()
                        return False
                else:
                    print(f"[ERROR] HTTP {response.status} for {url}")
                    return False
    except Exception as e:
        print(f"[ERROR] Failed to download {url}: {e}")
        return False

async def download_models_parallel(config, base_dir):
    """Download models in parallel with improved efficiency"""
    aria2c_available = check_aria2c()
    download_tasks = []
    
    for category, urls in config.items():
        cat_dir = base_dir / category
        for url in urls:
            # For Civitai URLs, we can't predict the final filename, so we'll check during download
            if "civitai.com" in url:
                download_tasks.append(download_with_aiohttp(url, cat_dir, category))
            elif aria2c_available:
                # For non-Civitai URLs, check if we already have the file
                filename = get_filename_from_url(url)
                dest = cat_dir / filename
                if dest.exists():
                    print(f"[SKIP] {dest} already exists.")
                    continue  # เพิ่ม continue เพื่อ skip
                # Only check for non-Civitai URLs since we know the exact filename
                download_tasks.append(download_with_aria2c(url, cat_dir))
            else:
                download_tasks.append(download_with_aiohttp(url, cat_dir, category))
    
    if not download_tasks:
        print("[INFO] All files already exist. No downloads needed.")
        return
    
    # Initialize progress tracking
    progress = DownloadProgress(len(download_tasks))
    
    # Use semaphore to limit concurrency
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)
    
    async def download_with_semaphore(task):
        async with semaphore:
            return await task
    
    # Run parallel downloads
    print(f"[DOWNLOAD] Starting parallel download of {len(download_tasks)} models...")
    results = await asyncio.gather(*[download_with_semaphore(task) for task in download_tasks], return_exceptions=True)
    
    # Count successful downloads
    success_count = sum(1 for r in results if r is True)
    failed_count = sum(1 for r in results if isinstance(r, Exception))
    
    # Calculate final statistics
    total_time = time.time() - progress.start_time
    avg_time_per_download = total_time / len(download_tasks) if download_tasks else 0
    
    print(f"[DOWNLOAD] Download completed: {success_count}/{len(download_tasks)} successful, {failed_count} failed")
    print(f"[STATS] Total time: {total_time:.1f}s, Average per download: {avg_time_per_download:.1f}s")
    
    if failed_count > 0:
        print(f"[WARNING] {failed_count} downloads failed. Check logs for details.")

async def main():
    config_path = "/models_config.json"
    base_dir = Path("/mnt/netdrive/comfyui/models")
    
    with open(config_path) as f:
        config = json.load(f)

    # Check existing files once
    print("[CHECK] Checking existing files in network volume...")
    existing_files = await check_existing_files(config, base_dir)

    await download_models_parallel(config, base_dir)

if __name__ == "__main__":
    asyncio.run(main())