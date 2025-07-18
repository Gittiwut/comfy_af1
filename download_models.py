import os
import json
import asyncio
from pathlib import Path
import shutil
import tempfile

def check_aria2c():
    if shutil.which("aria2c") is None:
        print("[ERROR] aria2c not found! Please install aria2c for fast downloads.")
        print("[INFO] Will use urllib fallback for downloads.")
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
        return
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
        else:
            print(f"[ERROR] aria2c failed for {url}, fallback to urllib. Reason: {stderr.decode()}")
            await download_with_urllib(url, dest)
    except FileNotFoundError:
        print(f"[ERROR] aria2c not found, using urllib fallback for {url}")
        await download_with_urllib(url, dest)
    except Exception as e:
        print(f"[ERROR] aria2c error for {url}: {e}, using urllib fallback")
        await download_with_urllib(url, dest)

async def download_with_urllib(url, dest):
    import urllib.request
    try:
        print(f"[MODEL] (fallback) Downloading: {url} -> {dest}")
        with urllib.request.urlopen(url) as response, tempfile.NamedTemporaryFile(dir=TMPDIR, delete=False) as tmp_file:
            shutil.copyfileobj(response, tmp_file)
            tmp_file_path = tmp_file.name
        shutil.move(tmp_file_path, dest)
        print(f"[MODEL] Downloaded: {dest}")
    except Exception as e:
        print(f"[ERROR] Failed to download {url}: {e}")

async def main():
    config_path = "/models_config.json"
    base_dir = Path("/mnt/netdrive/comfyui/models")
    with open(config_path) as f:
        config = json.load(f)
    tasks = []
    for category, urls in config.items():
        cat_dir = base_dir / category
        for url in urls:
            tasks.append(download_with_aria2c(url, cat_dir))
    await asyncio.gather(*tasks)

if __name__ == "__main__":
    asyncio.run(main())