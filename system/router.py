# router/router.py

import time
import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response

app = FastAPI(title="LLM Router")

# =====================
# Prometheus Metrics
# =====================
ROUTER_REQUESTS = Counter("router_requests_total", "Total router requests")
ROUTER_LATENCY = Histogram("router_latency_seconds", "Router latency")
WORKER_HEALTH = Gauge("router_worker_health", "Health of workers", ["worker"])

# ======================
# Worker list (TEMP)
# 实际部署中会做成 service discovery / 动态注册
# ======================
WORKERS = [
    "http://worker-0.llm-workers.svc.cluster.local:8000",
    "http://worker-1.llm-workers.svc.cluster.local:8000"
]

# Simple Round-Robin Routing
rr_index = 0
def pick_worker():
    global rr_index
    worker = WORKERS[rr_index % len(WORKERS)]
    rr_index += 1
    return worker

class GenerateRequest(BaseModel):
    prompt: str
    max_new_tokens: int = 64
    temperature: float = 0.7

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/route_generate")
async def route_generate(req: GenerateRequest):
    ROUTER_REQUESTS.inc()
    start_time = time.time()

    worker = pick_worker()

    try:
        async with httpx.AsyncClient(timeout=25.0) as client:
            resp = await client.post(f"{worker}/generate", json=req.dict())
            resp.raise_for_status()
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Worker failed: {str(e)}")

    ROUTER_LATENCY.observe(time.time() - start_time)
    return resp.json()

