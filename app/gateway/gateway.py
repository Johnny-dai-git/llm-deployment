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
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    token = authorization.split(" ", 1)[1].strip()
    if token != EXPECTED_API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API key")


# =====================
# Health & metrics
# =====================
@app.get("/health")
def health():
    return {"status": "ok", "router_url": ROUTER_URL}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# =====================
# OpenAI compatibility: /v1/models
# =====================
@app.get("/v1/models")
def list_models():
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
    # #region agent log
    import json
    try:
        with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
            f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"A","location":"gateway.py:139","message":"Gateway request received","data":{"model":req.model,"messages_count":len(req.messages),"max_tokens":req.max_tokens,"router_url":ROUTER_URL},"timestamp":int(time.time()*1000)})+'\n')
    except: pass
    # #endregion

    logger.info(
        f"[{request_id}] model={req.model}, messages={len(req.messages)}, max_tokens={req.max_tokens}"
    )

    GATEWAY_REQUESTS.labels(endpoint=endpoint).inc()
    start = time.time()

    check_api_key(authorization)

    # 2. Call router with OpenAI-compatible format
    payload = {
        "model": req.model,
        "messages": [msg.dict() for msg in req.messages],
        "max_tokens": req.max_tokens,
        "temperature": req.temperature,
    }

    # #region agent log
    import json
    try:
        with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
            f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"A","location":"gateway.py:163","message":"Before router call","data":{"router_url":ROUTER_URL,"payload_keys":list(payload.keys())},"timestamp":int(time.time()*1000)})+'\n')
    except: pass
    # #endregion
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            # #region agent log
            try:
                with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
                    f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"A","location":"gateway.py:166","message":"Calling router","data":{"url":f"{ROUTER_URL}/route_generate"},"timestamp":int(time.time()*1000)})+'\n')
            except: pass
            # #endregion
            resp = await client.post(
                f"{ROUTER_URL}/route_generate",
                json=payload,
            )
            # #region agent log
            try:
                with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
                    f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"A","location":"gateway.py:172","message":"Router response received","data":{"status_code":resp.status_code,"headers":dict(resp.headers)},"timestamp":int(time.time()*1000)})+'\n')
            except: pass
            # #endregion
            resp.raise_for_status()
            data = resp.json()
            # #region agent log
            try:
                with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
                    f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"E","location":"gateway.py:175","message":"Router response parsed","data":{"has_choices":"choices" in data,"choices_count":len(data.get("choices",[]))},"timestamp":int(time.time()*1000)})+'\n')
            except: pass
            # #endregion

    except httpx.TimeoutException:
        # #region agent log
        try:
            with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
                f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"D","location":"gateway.py:178","message":"Router timeout","data":{},"timestamp":int(time.time()*1000)})+'\n')
        except: pass
        # #endregion
        raise HTTPException(status_code=504, detail="Router timeout")

    except httpx.HTTPStatusError as e:
        # #region agent log
        try:
            with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
                f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"C","location":"gateway.py:183","message":"Router HTTP error","data":{"status_code":e.response.status_code,"response_text":e.response.text[:200] if hasattr(e.response,'text') else None},"timestamp":int(time.time()*1000)})+'\n')
        except: pass
        # #endregion
        logger.error(f"[{request_id}] router HTTP error {e.response.status_code}")
        raise HTTPException(
            status_code=502,
            detail=f"Router HTTP error: {e.response.status_code}",
        )

    except Exception as e:
        # #region agent log
        try:
            with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
                f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"A","location":"gateway.py:191","message":"Router exception","data":{"exception_type":type(e).__name__,"exception_msg":str(e)},"timestamp":int(time.time()*1000)})+'\n')
        except: pass
        # #endregion
        logger.exception(f"[{request_id}] router error")
        raise HTTPException(status_code=502, detail=str(e))

    latency = time.time() - start
    GATEWAY_LATENCY.labels(endpoint=endpoint).observe(latency)

    # 3. Parse Router OpenAI-style response
    output_text = ""
    # #region agent log
    try:
        with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
            f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"E","location":"gateway.py:196","message":"Before parsing response","data":{"data_keys":list(data.keys()) if isinstance(data,dict) else "not_dict"},"timestamp":int(time.time()*1000)})+'\n')
    except: pass
    # #endregion
    if "choices" in data and data["choices"]:
        choice = data["choices"][0]
        if "message" in choice and "content" in choice["message"]:
            output_text = choice["message"]["content"]
            # #region agent log
            try:
                with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
                    f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"E","location":"gateway.py:201","message":"Extracted output text","data":{"output_length":len(output_text)},"timestamp":int(time.time()*1000)})+'\n')
            except: pass
            # #endregion

    if not output_text:
        # #region agent log
        try:
            with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
                f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"E","location":"gateway.py:207","message":"Empty response from router","data":{"data":str(data)[:500]},"timestamp":int(time.time()*1000)})+'\n')
        except: pass
        # #endregion
        raise HTTPException(status_code=502, detail="Empty response from router")

    logger.info(f"[{request_id}] done in {latency:.3f}s")
    # #region agent log
    try:
        with open('/home/ubuntu/k8s/llm-deployment/.cursor/debug.log', 'a') as f:
            f.write(json.dumps({"sessionId":"debug-session","runId":"run1","hypothesisId":"E","location":"gateway.py:220","message":"Gateway returning success","data":{"latency":latency,"output_length":len(output_text)},"timestamp":int(time.time()*1000)})+'\n')
    except: pass
    # #endregion

    # 4. Return OpenAI-compatible response
    return ChatCompletionResponse(
        id=data.get("id", f"chatcmpl-{int(time.time() * 1000)}"),
        created=int(time.time()),
        model=req.model,
        choices=[
            ChatCompletionChoice(
                index=0,
                message=ChatMessage(role="assistant", content=output_text),
                finish_reason="stop",
            )
        ],
    )
