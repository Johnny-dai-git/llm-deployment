FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update && apt-get install -y \
    python3.10 python3-pip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip

# Pin transformers to 4.57.6 — vLLM 0.11.0 doesn't support transformers 5.x:
#   AttributeError: Qwen2Tokenizer has no attribute all_special_tokens_extended
# See: https://github.com/QwenLM/Qwen3-VL/issues/2058
RUN pip install vllm==0.11.0 transformers==4.57.6 --extra-index-url https://download.pytorch.org/whl/cu122

# On A100 / H100 we let vLLM use its preferred backends (FlashAttention 2,
# CUDA Graph, cascade attention). The RTX-specific defensive disables that
# the laptop branch has are intentionally NOT set here.
