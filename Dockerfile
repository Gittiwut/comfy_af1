FROM python:3.10-slim

# ติดตั้ง Git (จำเป็นสำหรับการ clone ComfyUI)
RUN apt-get update && apt-get install -y \
    --no-install-recommends git curl bash \
    && rm -rf /var/lib/apt/lists/*

# ตั้ง root path สำหรับ ComfyUI
ENV COMFYUI_ROOT=/mnt/netdrive/comfyui
WORKDIR /mnt/netdrive/comfyui

# ติดตั้ง Python packages ที่ขาด
COPY requirements.txt /mnt/netdrive/comfyui/requirements.txt
RUN pip install -r /mnt/netdrive/comfyui/requirements.txt

# สร้าง entry ให้ download essential module ตอนรันสตาร์ท
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD []

# แนบไฟล์ custom_nodes, model ไปลงไว้ใน netdrive
COPY custom_nodes_list.json /opt/custom_nodes_list.json
COPY models_config.json /opt/models_config.json

# เปิด port ตาม RunPod
EXPOSE 8188
EXPOSE 8888