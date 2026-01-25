FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update && apt-get install -y \
    python3.10 python3-pip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip

# 关键：让 vllm 自己选择兼容 torch / CUDA
RUN pip install vllm==0.11.0 --extra-index-url https://download.pytorch.org/whl/cu122

# RTX / 消费级卡稳定性
ENV VLLM_USE_FLASH_ATTENTION=0
ENV VLLM_DISABLE_FLASH_ATTN=1
