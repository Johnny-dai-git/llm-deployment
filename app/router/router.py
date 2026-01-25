# router/router.py

import time
import logging
import httpx
from typing import List, Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response

# =====================
# Logging
# =====================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("router")

# =====================
# FastAPI App
# =====================
app = FastAPI(title="LLM Router (OpenAI-compatible)")

# =====================
# Metrics
# =====================
ROUTER_REQUESTS = Counter("router_requests_total", "Total router requests")
ROUTER_LATENCY = Histogram("router_latency_seconds", "Router latency")

# =====================
# Worker config
# =====================
WORKER_URL = "http://vllm-worker-service.llm.svc.cluster.local:8002"

# =====================
# OpenAI schemas
# =====================
class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str

class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    max_tokens: int = 128
    temperature: float = 0.7

# =====================
# Health / metrics
# =====================
@app.get("/health")
def health():
    return {"status": "ok", "worker": WORKER_URL}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# =====================
# Core API
# =====================
@app.post("/route_generate")
async def route_generate(req: ChatCompletionRequest):
    request_id = f"req_{int(time.time() * 1000)}"
    start = time.time()

    ROUTER_REQUESTS.inc()
    logger.info(f"[{request_id}] routing to vLLM")

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{WORKER_URL}/v1/chat/completions",
                json=req.dict(),
            )
            resp.raise_for_status()
            data = resp.json()

    except httpx.HTTPStatusError as e:
        logger.error(f"[{request_id}] worker error {e.response.status_code}")
        raise HTTPException(status_code=502, detail="Worker HTTP error")

    except Exception as e:
        logger.exception(f"[{request_id}] worker failed")
        raise HTTPException(status_code=502, detail=str(e))

    latency = time.time() - start
    ROUTER_LATENCY.observe(latency)

    logger.info(f"[{request_id}] done in {latency:.3f}s")
    return data
