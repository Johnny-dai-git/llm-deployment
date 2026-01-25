# gateway/gateway.py

import os
import time
import logging
import httpx
from typing import List, Optional, Literal

from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response

# =====================
# Logging
# =====================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("gateway")

log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logger.setLevel(getattr(logging, log_level, logging.INFO))

# =====================
# Router config
# =====================
ROUTER_SERVICE_HOST = os.environ.get("ROUTER_SERVICE_HOST")
ROUTER_SERVICE_PORT = os.environ.get("ROUTER_SERVICE_PORT", "80")

if ROUTER_SERVICE_HOST:
    ROUTER_URL = f"http://{ROUTER_SERVICE_HOST}:{ROUTER_SERVICE_PORT}"
else:
    ROUTER_URL = os.environ.get(
        "ROUTER_URL",
        "http://router-service.llm.svc.cluster.local:80",
    )

logger.info(f"Using ROUTER_URL: {ROUTER_URL}")

EXPECTED_API_KEY = os.environ.get("API_KEY")  # optional

# =====================
# FastAPI app
# =====================
app = FastAPI(title="LLM API Gateway (OpenAI-compatible)")

# =====================
# Prometheus metrics
# =====================
GATEWAY_REQUESTS = Counter(
    "gateway_requests_total",
    "Total API requests",
    ["endpoint"],
)
GATEWAY_LATENCY = Histogram(
    "gateway_request_latency_seconds",
    "API request latency",
    ["endpoint"],
)

# =====================
# OpenAI-style schemas
# =====================
class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class ChatCompletionRequest(BaseModel):
    model: str = Field(..., description="Logical model name")
    messages: List[ChatMessage]
    max_tokens: int = 128
    temperature: float = 0.7


class ChatCompletionChoice(BaseModel):
    index: int
    message: ChatMessage
    finish_reason: str


class ChatCompletionResponse(BaseModel):
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: List[ChatCompletionChoice]


# =====================
# Helpers
# =====================
def check_api_key(authorization: Optional[str]):
    if EXPECTED_API_KEY is None:
        return
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail="Missing or invalid Authorization header",
        )
    token = authorization.split(" ", 1)[1].strip()
    if token != EXPECTED_API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API key")


# =====================
# Health & metrics
# =====================
@app.get("/health")
def health():
    return {
        "status": "ok",
        "router_url": ROUTER_URL,
    }


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# =====================
# OpenAI compatibility: /v1/models
# =====================
@app.get("/v1/models")
def list_models():
    """
    WebUI / OpenAI SDK / LangChain
    页面加载时会调用一次
    """
    return {
        "object": "list",
        "data": [
            {
                "id": "qwen2.5-0.5b",
                "object": "model",
                "owned_by": "local",
            }
        ],
    }


# =====================
# Core API: /v1/chat/completions
# =====================
@app.post("/v1/chat/completions", response_model=ChatCompletionResponse)
async def chat_completions(
    req: ChatCompletionRequest,
    authorization: Optional[str] = Header(default=None),
):
    request_id = f"gw_{int(time.time() * 1000)}"
    endpoint = "/v1/chat/completions"

    logger.info(
        f"[{request_id}] model={req.model}, "
        f"messages={len(req.messages)}, max_tokens={req.max_tokens}"
    )

    GATEWAY_REQUESTS.labels(endpoint=endpoint).inc()
    start = time.time()

    # 1. API key check (optional)
    check_api_key(authorization)

    # 2. Forward request to router (OpenAI Chat format, NO transformation)
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{ROUTER_URL}/route_generate",
                json=req.dict(),
            )
            resp.raise_for_status()
            data = resp.json()

    except httpx.TimeoutException:
        logger.error(f"[{request_id}] router timeout")
        raise HTTPException(status_code=504, detail="Router timeout")

    except httpx.HTTPStatusError as e:
        logger.error(
            f"[{request_id}] router HTTP error {e.response.status_code}"
        )
        raise HTTPException(
            status_code=502,
            detail=f"Router HTTP error: {e.response.status_code}",
        )

    except Exception as e:
        logger.exception(f"[{request_id}] router error")
        raise HTTPException(status_code=502, detail=f"Router error: {str(e)}")

    latency = time.time() - start
    GATEWAY_LATENCY.labels(endpoint=endpoint).observe(latency)

    logger.info(
        f"[{request_id}] done in {latency:.3f}s"
    )

    # 3. Router already returns OpenAI-style response
    return ChatCompletionResponse(**data)
