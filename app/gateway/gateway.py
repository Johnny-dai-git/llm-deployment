# gateway/gateway.py
# 合并自原 gateway + router 两个组件,直接面向 vllm-worker。
# 当前为单模型场景;未来上多模型时可再拆出独立 router。

import os
import time
import logging
import httpx
from typing import List, Optional, Literal

from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response, StreamingResponse

# =====================
# Logging
# =====================
log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, log_level, logging.INFO),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("llm-api")

# =====================
# Worker config(直接指向 vllm-worker,不再经过 router)
# =====================
WORKER_HOST = os.environ.get(
    "VLLM_WORKER_HOST", "vllm-worker-service.llm.svc.cluster.local"
)
WORKER_PORT = os.environ.get("VLLM_WORKER_PORT", "8002")
WORKER_URL = f"http://{WORKER_HOST}:{WORKER_PORT}"
logger.info(f"Using WORKER_URL: {WORKER_URL}")

EXPECTED_API_KEY = os.environ.get("API_KEY")  # optional

# 请求超时(LLM 长生成需要较长时间,默认 300s)
WORKER_TIMEOUT = float(os.environ.get("WORKER_TIMEOUT", "300"))

# =====================
# FastAPI app
# =====================
app = FastAPI(title="LLM API (OpenAI-compatible, gateway+router merged)")

# =====================
# Prometheus metrics
# =====================
API_REQUESTS = Counter(
    "llm_api_requests_total",
    "Total API requests",
    ["endpoint"],
)
API_LATENCY = Histogram(
    "llm_api_request_latency_seconds",
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
    stream: bool = False              # OpenAI 兼容:true 时走 SSE 流式


# =====================
# Helpers
# =====================
def check_api_key(authorization: Optional[str]):
    if EXPECTED_API_KEY is None:
        return
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=401, detail="Missing or invalid Authorization header"
        )
    token = authorization.split(" ", 1)[1].strip()
    if token != EXPECTED_API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API key")


# =====================
# Health & metrics
# =====================
@app.get("/health")
def health():
    return {"status": "ok", "worker_url": WORKER_URL}


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
# Core API: /v1/chat/completions —— 直接打 vllm-worker
# =====================
@app.post("/v1/chat/completions")
async def chat_completions(
    req: ChatCompletionRequest,
    authorization: Optional[str] = Header(default=None),
):
    request_id = f"api_{int(time.time() * 1000)}"
    endpoint = "/v1/chat/completions"

    API_REQUESTS.labels(endpoint=endpoint).inc()
    start = time.time()

    check_api_key(authorization)

    payload = {
        "model": req.model,
        "messages": [m.dict() for m in req.messages],
        "max_tokens": req.max_tokens,
        "temperature": req.temperature,
        "stream": req.stream,
    }

    logger.info(
        f"[{request_id}] model={req.model}, messages={len(req.messages)}, "
        f"max_tokens={req.max_tokens}, stream={req.stream}"
    )

    # ============ 流式分支 ============
    # vLLM 已经支持 stream=true 并以 SSE 格式吐 chunks。
    # 这里我们做"透传式代理":把 vLLM 的 SSE 流原样转给客户端。
    if req.stream:
        async def sse_proxy():
            try:
                async with httpx.AsyncClient(timeout=WORKER_TIMEOUT) as client:
                    async with client.stream(
                        "POST",
                        f"{WORKER_URL}/v1/chat/completions",
                        json=payload,
                    ) as resp:
                        resp.raise_for_status()
                        async for chunk in resp.aiter_raw():
                            yield chunk
            except Exception as e:
                # SSE 中途出错:headers 已经发出去,只能 yield 一个错误事件
                logger.exception(f"[{request_id}] streaming error: {e}")
                err_payload = (
                    f'data: {{"error": {{"message": "{str(e)[:200]}", '
                    f'"type": "{type(e).__name__}"}}}}\n\n'
                    f'data: [DONE]\n\n'
                )
                yield err_payload.encode()
            finally:
                latency = time.time() - start
                API_LATENCY.labels(endpoint=endpoint).observe(latency)
                logger.info(f"[{request_id}] stream done in {latency:.3f}s")

        return StreamingResponse(
            sse_proxy(),
            media_type="text/event-stream",
            headers={
                # 显式告知任何中间代理"别 buffer 我"
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )

    # ============ 非流式分支(原有逻辑) ============
    try:
        async with httpx.AsyncClient(timeout=WORKER_TIMEOUT) as client:
            resp = await client.post(
                f"{WORKER_URL}/v1/chat/completions",
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()

    except httpx.ConnectError as e:
        logger.error(f"[{request_id}] worker connection error: {e}")
        raise HTTPException(
            status_code=502, detail=f"Worker connection error: {e}"
        )

    except httpx.TimeoutException:
        logger.error(f"[{request_id}] worker timeout")
        raise HTTPException(status_code=504, detail="Worker timeout")

    except httpx.HTTPStatusError as e:
        # vLLM 返回非 2xx 时:
        #   - 4xx 是 client 端问题(unknown model / invalid messages / 等),
        #     按 OpenAI 兼容标准应该原样透传给客户端,带上 vllm 的 error body,
        #     这样前端能区分"是我输入错了"还是"服务挂了"
        #   - 5xx 是 vllm 内部错误,我们包装成 502 不暴露上游细节
        upstream_code = e.response.status_code
        body_text = e.response.text[:500] if hasattr(e.response, "text") else ""
        logger.error(
            f"[{request_id}] worker HTTP {upstream_code}: {body_text}"
        )
        if 400 <= upstream_code < 500:
            # 把 vllm 的 error JSON 透传出去
            try:
                err_detail = e.response.json()
            except Exception:
                err_detail = {
                    "error": {
                        "message": body_text or "upstream error",
                        "type": "upstream_error",
                        "code": upstream_code,
                    }
                }
            raise HTTPException(status_code=upstream_code, detail=err_detail)
        # 5xx → 502
        raise HTTPException(
            status_code=502,
            detail=f"Worker HTTP error {upstream_code}",
        )

    except Exception as e:
        logger.exception(f"[{request_id}] worker failed: {e}")
        raise HTTPException(status_code=502, detail=f"Worker error: {e}")

    latency = time.time() - start
    API_LATENCY.labels(endpoint=endpoint).observe(latency)
    logger.info(f"[{request_id}] done in {latency:.3f}s")

    # vLLM 已经返回 OpenAI 兼容格式,直接透传(避免再解包/重包)
    return data

# CI smoke test Mon May  4 02:25:29 AM EDT 2026
