# router/router.py

import os
import time
import httpx
import logging
from typing import Optional, List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response

# =====================
# Logging
# =====================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - [%(filename)s:%(lineno)d] - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("router")

log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logger.setLevel(getattr(logging, log_level, logging.INFO))

# =====================
# FastAPI App
# =====================
app = FastAPI(title="LLM Router (vLLM only)")

# =====================
# Prometheus Metrics
# =====================
ROUTER_REQUESTS = Counter("router_requests_total", "Total router requests")
ROUTER_LATENCY = Histogram("router_latency_seconds", "Router latency")

# =====================
# Worker Configuration
# =====================
class WorkerConfig:
    def __init__(self, url: str, api_endpoint: str):
        self.url = url
        self.api_endpoint = api_endpoint
        logger.info(f"Registered worker: url={url}, endpoint={api_endpoint}")

def build_workers_list() -> List[WorkerConfig]:
    logger.info("Building worker list (vLLM only)")
    return [
        WorkerConfig(
            url="http://vllm-worker-service.llm.svc.cluster.local:8002",
            api_endpoint="/v1/completions",
        )
    ]

WORKERS = build_workers_list()

# =====================
# Startup
# =====================
@app.on_event("startup")
async def startup_event():
    logger.info("=" * 60)
    logger.info("Router starting up")
    logger.info(f"Total workers: {len(WORKERS)}")
    for i, w in enumerate(WORKERS):
        logger.info(f"  Worker {i+1}: {w.url}{w.api_endpoint}")
    logger.info("=" * 60)

# =====================
# Round-robin worker picker
# =====================
_rr_index = 0

def pick_worker() -> WorkerConfig:
    global _rr_index
    if not WORKERS:
        raise HTTPException(status_code=503, detail="No workers available")
    worker = WORKERS[_rr_index % len(WORKERS)]
    _rr_index += 1
    return worker

# =====================
# Request / Response Models
# =====================
class GenerateRequest(BaseModel):
    prompt: str
    max_new_tokens: int = 64
    temperature: float = 0.7

# =====================
# Health & Metrics
# =====================
@app.get("/health")
async def health():
    return {
        "status": "ok",
        "workers": [
            {"url": w.url, "endpoint": w.api_endpoint} for w in WORKERS
        ],
    }

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# =====================
# Core API
# =====================
@app.post("/route_generate")
async def route_generate(req: GenerateRequest):
    request_id = f"req_{int(time.time() * 1000)}"
    start = time.time()

    logger.info(
        f"[{request_id}] route_generate: prompt_len={len(req.prompt)}, "
        f"max_tokens={req.max_new_tokens}, temp={req.temperature}"
    )

    ROUTER_REQUESTS.inc()

    worker = pick_worker()
    logger.info(f"[{request_id}] Using worker {worker.url}")

    payload = {
        "model": "qwen2.5-0.5b",
        "prompt": req.prompt,
        "max_tokens": req.max_new_tokens,
        "temperature": req.temperature,
    }

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{worker.url}{worker.api_endpoint}",
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()
    except httpx.TimeoutException:
        logger.error(f"[{request_id}] Worker timeout")
        raise HTTPException(status_code=504, detail="Worker timeout")
    except httpx.HTTPStatusError as e:
        logger.error(
            f"[{request_id}] Worker HTTP error: {e.response.status_code} {e.response.text[:200]}"
        )
        raise HTTPException(status_code=503, detail="Worker HTTP error")
    except Exception as e:
        logger.exception(f"[{request_id}] Worker failed")
        raise HTTPException(status_code=503, detail=str(e))

    # Parse vLLM response
    output = ""
    if "choices" in data and data["choices"]:
        output = data["choices"][0].get("text", "")

    latency = time.time() - start
    ROUTER_LATENCY.observe(latency)

    logger.info(
        f"[{request_id}] Done in {latency:.3f}s, output_len={len(output)}"
    )

    return {"output": output}

