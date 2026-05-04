# llm-serving/gateway/Dockerfile

FROM python:3.10-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY gateway.py /app/gateway.py

ENV PYTHONUNBUFFERED=1 \
    VLLM_WORKER_HOST=vllm-worker-service.llm.svc.cluster.local \
    VLLM_WORKER_PORT=8002 \
    WORKER_TIMEOUT=300

EXPOSE 8000

CMD ["uvicorn", "gateway:app", "--host", "0.0.0.0", "--port", "8000"]

