FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update && apt-get install -y \
    python3.10 python3-pip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip

# 关键：让 vllm 自己选择兼容 torch / CUDA
# transformers 必须固定到 4.57.6 — vllm 0.11.0 还不支持 transformers 5.x,
# 用最新版 transformers 会报:
#   AttributeError: Qwen2Tokenizer has no attribute all_special_tokens_extended
# 见 https://github.com/QwenLM/Qwen3-VL/issues/2058
RUN pip install vllm==0.11.0 transformers==4.57.6 --extra-index-url https://download.pytorch.org/whl/cu122

# RTX / 消费级卡稳定性
ENV VLLM_USE_FLASH_ATTENTION=0
ENV VLLM_DISABLE_FLASH_ATTN=1
