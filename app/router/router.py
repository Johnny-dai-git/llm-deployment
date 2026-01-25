# router/router.py

import os
import time
import logging
import httpx
from typing import List, Optional, Literal

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
app = FastAPI(title="LLM Router (chat passthrough)")

# =====================
# Prometheus Metrics
# =====================
ROUTER_REQUESTS = Counter("router_requests_total", "Total router requests")
ROUTER_LATENCY = Histogram("router_latency_seconds", "Router latency")

# =====================
# Worker Configuration
# =====================
class WorkerConfig:
    def __init__(self, url: str):
        self.url = url
        logger.info(f"Registered worker: {url}")

def build_workers() -> List[WorkerConfig]:
    # vLLM OpenAI-compatible API
    return [
        WorkerConfig(
            url="http://vllm-worker-service.llm.svc.cluster.local:8002"
        )
    ]

WORKERS = build_workers()

# =====================
# Startup
# =====================
@app.on_event("startup")
async def startup_event():
    logger.info("=" * 60)
    logger.info("Router starting (chat passthrough mode)")
    logger.info(f"Workers: {len(WORKERS)}")
    for i, w in enumerate(WORKERS):
        logger.info(f"  Worker {i+1}: {w.url}")
    logger.info("=" * 60)

# =====================
# Round-robin picker
# =====================
_rr_index = 0

def pick_worker() -> WorkerConfig:
    global _rr_index
    if not WORKERS:
        raise HTTPException(status_code=503, detail="No workers available")
    w = WORKERS[_rr_index % len(WORKERS)]
    _rr_index += 1
    return w

# =====================
# OpenAI Chat Schemas (minimal)
# =====================
class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str

class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    max_tokens: Optional[int] = 128
    temperature: Optional[float] = 0.7

# =====================
# Health & Metrics
# =====================
@app.get("/health")
async def health():
    return {
        "status": "ok",
        "workers": [w.url for w in WORKERS],
    }

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# =====================
# Core API
# =====================
@app.post("/route_generate")
async def route_generate(req: ChatCompletionRequest):
    """
    🔥 关键语义：
    - Gateway 传什么，这里就转什么
    - Router 不碰 prompt，不改 messages
    """
    request_id = f"rt_{int(time.time() * 1000)}"
    start = time.time()
    ROUTER_REQUESTS.inc()

    logger.info(
        f"[{request_id}] model={req.model}, messages={len(req.messages)}"
    )

    worker = pick_worker()
    logger.info(f"[{request_id}] Using worker {worker.url}")

    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                f"{worker.url}/v1/chat/completions",
                json=req.dict(),
            )
            resp.raise_for_status()
            data = resp.json()

    except httpx.TimeoutException:
        logger.error(f"[{request_id}] Worker timeout")
        raise HTTPException(status_code=504, detail="Worker timeout")

    except httpx.HTTPStatusError as e:
        logger.error(
            f"[{request_id}] Worker HTTP error {e.response.status_code}: "
            f"{e.response.text[:200]}"
        )
        raise HTTPException(status_code=503, detail="Worker HTTP error")

    except Exception as e:
        logger.exception(f"[{request_id}] Worker error")
        raise HTTPException(status_code=503, detail=str(e))

    # ✅ 抽取 assistant 内容，统一给 Gateway
    output = ""
    try:
        output = data["choices"][0]["message"]["content"]
    except Exception:
        logger.error(f"[{request_id}] Invalid vLLM response format")
        raise HTTPException(status_code=502, detail="Invalid worker response")

    latency = time.time() - start
    ROUTER_LATENCY.observe(latency)

    logger.info(
        f"[{request_id}] Done in {latency:.3f}s, output_len={len(output)}"
    )

    return {"output": output}
