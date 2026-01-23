# gateway/gateway.py

import os
import sys
import time
import logging
import httpx
from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel, Field
from typing import List, Optional, Literal
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response

# =====================
# 日志配置
# =====================
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - [%(filename)s:%(lineno)d] - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

# 从环境变量获取日志级别（可选）
log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logger.setLevel(getattr(logging, log_level, logging.INFO))

# ======================
# 配置
# ======================
# 从环境变量构建 ROUTER_URL，支持两种方式：
# 1. 直接设置 ROUTER_URL
# 2. 通过 ROUTER_SERVICE_HOST 和 ROUTER_SERVICE_PORT 构建
ROUTER_SERVICE_HOST = os.environ.get("ROUTER_SERVICE_HOST")
ROUTER_SERVICE_PORT = os.environ.get("ROUTER_SERVICE_PORT", "80")

if ROUTER_SERVICE_HOST:
    # 使用 Kubernetes Service DNS
    ROUTER_URL = f"http://{ROUTER_SERVICE_HOST}:{ROUTER_SERVICE_PORT}"
    logger.info(f"Using ROUTER_URL from ROUTER_SERVICE_HOST: {ROUTER_URL}")
else:
    # 回退到直接配置的 ROUTER_URL 或默认值
    ROUTER_URL = os.environ.get("ROUTER_URL", "http://router-service.llm.svc.cluster.local:80")
    logger.info(f"Using ROUTER_URL: {ROUTER_URL}")

EXPECTED_API_KEY = os.environ.get("API_KEY")  # 可选，不设置则不校验

app = FastAPI(title="LLM API Gateway")

# ======================
# Prometheus 指标
# ======================
GATEWAY_REQUESTS = Counter("gateway_requests_total", "Total API requests", ["endpoint"])
GATEWAY_LATENCY = Histogram("gateway_request_latency_seconds", "API request latency", ["endpoint"])

# ======================
# OpenAI 风格请求/响应模型
# ======================
class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str

class ChatCompletionRequest(BaseModel):
    model: str = Field(..., description="Logical model name, e.g. hcc-coder-v1")
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

# ======================
# 工具函数
# ======================
def check_api_key(authorization: Optional[str]):
    if EXPECTED_API_KEY is None:
        return  # 不启用校验
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    token = authorization.split(" ", 1)[1].strip()
    if token != EXPECTED_API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API key")

def build_prompt_from_messages(messages: List[ChatMessage]) -> str:
    # 简单版本：把所有对话拼成一个 prompt
    lines = []
    for msg in messages:
        prefix = {
            "system": "[SYSTEM]",
            "user": "[USER]",
            "assistant": "[ASSISTANT]"
        }.get(msg.role, "[USER]")
        lines.append(f"{prefix} {msg.content}")
    return "\n".join(lines)

# ======================
# 健康检查 & metrics
# ======================
@app.get("/health")
def health():
    return {
        "status": "ok",
        "router_url": ROUTER_URL
    }

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# ======================
# 核心 API：/v1/chat/completions
# ======================
@app.post("/v1/chat/completions", response_model=ChatCompletionResponse)
async def chat_completions(
    req: ChatCompletionRequest,
    authorization: Optional[str] = Header(default=None)
):
    request_id = f"gateway_{int(time.time() * 1000)}"
    endpoint = "/v1/chat/completions"
    logger.info(f"[{request_id}] Received chat completion request: model={req.model}, "
                f"messages_count={len(req.messages)}, max_tokens={req.max_tokens}")
    
    GATEWAY_REQUESTS.labels(endpoint=endpoint).inc()
    start = time.time()

    # 1. 校验 API Key（可选）
    check_api_key(authorization)

    # 2. 把 messages 转成 prompt
    prompt = build_prompt_from_messages(req.messages)
    logger.debug(f"[{request_id}] Built prompt: length={len(prompt)}")

    # 3. 调用 Router 的 /route_generate
    router_payload = {
        "prompt": prompt,
        "max_new_tokens": req.max_tokens,
        "temperature": req.temperature
    }

    try:
        logger.info(f"[{request_id}] Calling router at {ROUTER_URL}/route_generate")
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(f"{ROUTER_URL}/route_generate", json=router_payload)
            resp.raise_for_status()
            data = resp.json()
            logger.info(f"[{request_id}] Received response from router: status={resp.status_code}, "
                       f"output_length={len(data.get('output', ''))}")
    except httpx.TimeoutException as e:
        logger.error(f"[{request_id}] Timeout while calling router: {e}")
        raise HTTPException(status_code=504, detail=f"Router timeout: {str(e)}")
    except httpx.HTTPStatusError as e:
        logger.error(f"[{request_id}] HTTP error from router: status={e.response.status_code}, "
                    f"response={e.response.text[:200]}")
        raise HTTPException(status_code=502, detail=f"Router HTTP error: {e.response.status_code}")
    except Exception as e:
        logger.error(f"[{request_id}] Router error: {type(e).__name__}: {e}", exc_info=True)
        raise HTTPException(status_code=502, detail=f"Router error: {str(e)}")

    latency = time.time() - start
    GATEWAY_LATENCY.labels(endpoint=endpoint).observe(latency)

    # 4. 转成 OpenAI 风格响应
    completion = ChatCompletionResponse(
        id=f"chatcmpl-{int(time.time()*1000)}",
        created=int(time.time()),
        model=req.model,
        choices=[
            ChatCompletionChoice(
                index=0,
                message=ChatMessage(role="assistant", content=data.get("output", "")),
                finish_reason="stop"
            )
        ]
    )
    
    logger.info(f"[{request_id}] Request completed: latency={latency:.3f}s")
    return completion

