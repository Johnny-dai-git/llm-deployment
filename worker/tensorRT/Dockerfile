FROM nvcr.io/nvidia/ai-dynamo/tensorrtllm-runtime:0.7.0

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    vim \
    htop \
    curl \
    jq \
    net-tools \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    loguru \
    python-json-logger \
    prometheus_client \
    nvidia-ml-py3

