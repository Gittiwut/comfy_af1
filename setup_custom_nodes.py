import json
import asyncio
from pathlib import Path
import subprocess
import datetime

async def clone_repo(name, repo, base_dir):
    dest = base_dir / name
    if dest.exists():
        print(f"[SKIP] {name} already exists.")
        return
    print(f"[CLONE] {repo} -> {dest}")
    proc = await asyncio.create_subprocess_exec(
        "git", "clone", "--depth=1", repo, str(dest),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode == 0:
        print(f"[CLONE] Success: {name}")
    else:
        print(f"[CLONE] Failed: {name}\n{stderr.decode()}")

async def install_requirements(base_dir):
    reqs = list(base_dir.glob("*/requirements.txt"))
    tasks = []
    for req in reqs:
        print(f"[REQ] Installing {req}")
        tasks.append(asyncio.create_subprocess_exec(
            "uv", "pip", "install", "--python=/mnt/netdrive/python_env/bin/python", "--no-cache", "-r", str(req),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        ))
    procs = await asyncio.gather(*tasks)
    for i, proc in enumerate(procs):
        stdout, stderr = await proc.communicate()
        if proc.returncode == 0:
            print(f"[REQ] Success: {reqs[i]}")
        else:
            print(f"[REQ] Failed: {reqs[i]}\n{stderr.decode()}")

async def main():
    base_dir = Path("/mnt/netdrive/comfyui/custom_nodes")
    base_dir.mkdir(parents=True, exist_ok=True)
    with open("/custom_nodes_list.json") as f:
        nodes = json.load(f)
    tasks = []
    for name, repos in nodes.items():
        for repo in repos:
            tasks.append(clone_repo(name, repo, base_dir))
    await asyncio.gather(*tasks)
    await install_requirements(base_dir)

if __name__ == "__main__":
    asyncio.run(main()) 