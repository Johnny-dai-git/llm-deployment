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
import os
VLLM_WORKER_HOST = os.environ.get("VLLM_WORKER_HOST", "vllm-worker-service.llm.svc.cluster.local")
VLLM_WORKER_PORT = os.environ.get("VLLM_WORKER_PORT", "8002")
WORKER_URL = f"http://{VLLM_WORKER_HOST}:{VLLM_WORKER_PORT}"
logger.info(f"Using WORKER_URL: {WORKER_URL}")

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
    # #region agent log
    import json
    debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"B","location":"router.py:66","message":"Router request received","data":{"worker_url":WORKER_URL,"model":req.model,"messages_count":len(req.messages)},"timestamp":int(time.time()*1000)}
    logger.info(f"[DEBUG] {json.dumps(debug_data)}")
    try:
        with open('/tmp/debug.log', 'a') as f:
            f.write(json.dumps(debug_data)+'\n')
    except Exception as e:
        logger.warning(f"[DEBUG] Failed to write log file: {e}")
    # #endregion

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            # #region agent log
            req_dict = req.dict()
            debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"B","location":"router.py:74","message":"Calling worker","data":{"url":f"{WORKER_URL}/v1/chat/completions","payload":req_dict},"timestamp":int(time.time()*1000)}
            logger.info(f"[DEBUG] {json.dumps(debug_data)}")
            try:
                with open('/tmp/debug.log', 'a') as f:
                    f.write(json.dumps(debug_data)+'\n')
            except Exception as e:
                logger.warning(f"[DEBUG] Failed to write log file: {e}")
            # #endregion
            resp = await client.post(
                f"{WORKER_URL}/v1/chat/completions",
                json=req_dict,
            )
            # #region agent log
            debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"C","location":"router.py:80","message":"Worker response received","data":{"status_code":resp.status_code},"timestamp":int(time.time()*1000)}
            logger.info(f"[DEBUG] {json.dumps(debug_data)}")
            try:
                with open('/tmp/debug.log', 'a') as f:
                    f.write(json.dumps(debug_data)+'\n')
            except Exception as e:
                logger.warning(f"[DEBUG] Failed to write log file: {e}")
            # #endregion
            resp.raise_for_status()
            data = resp.json()
            # #region agent log
            debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"C","location":"router.py:84","message":"Worker response parsed","data":{"has_choices":"choices" in data if isinstance(data,dict) else False},"timestamp":int(time.time()*1000)}
            logger.info(f"[DEBUG] {json.dumps(debug_data)}")
            try:
                with open('/tmp/debug.log', 'a') as f:
                    f.write(json.dumps(debug_data)+'\n')
            except Exception as e:
                logger.warning(f"[DEBUG] Failed to write log file: {e}")
            # #endregion

    except httpx.ConnectError as e:
        # #region agent log
        debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"B","location":"router.py:123","message":"Worker connection error","data":{"exception_type":type(e).__name__,"exception_msg":str(e),"worker_url":WORKER_URL},"timestamp":int(time.time()*1000)}
        logger.error(f"[DEBUG] {json.dumps(debug_data)}")
        try:
            with open('/tmp/debug.log', 'a') as f:
                f.write(json.dumps(debug_data)+'\n')
        except Exception as e2:
            logger.warning(f"[DEBUG] Failed to write log file: {e2}")
        # #endregion
        logger.error(f"[{request_id}] worker connection error: {e}")
        raise HTTPException(status_code=502, detail=f"Worker connection error: {str(e)}")

    except httpx.TimeoutException as e:
        # #region agent log
        debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"D","location":"router.py:135","message":"Worker timeout","data":{"exception_type":type(e).__name__,"exception_msg":str(e),"worker_url":WORKER_URL},"timestamp":int(time.time()*1000)}
        logger.error(f"[DEBUG] {json.dumps(debug_data)}")
        try:
            with open('/tmp/debug.log', 'a') as f:
                f.write(json.dumps(debug_data)+'\n')
        except Exception as e2:
            logger.warning(f"[DEBUG] Failed to write log file: {e2}")
        # #endregion
        logger.error(f"[{request_id}] worker timeout")
        raise HTTPException(status_code=504, detail="Worker timeout")

    except httpx.HTTPStatusError as e:
        # #region agent log
        response_text = ""
        try:
            if hasattr(e.response, 'text'):
                response_text = e.response.text[:500]
        except:
            pass
        debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"C","location":"router.py:149","message":"Worker HTTP error","data":{"status_code":e.response.status_code,"response_text":response_text,"worker_url":WORKER_URL},"timestamp":int(time.time()*1000)}
        logger.error(f"[DEBUG] {json.dumps(debug_data)}")
        try:
            with open('/tmp/debug.log', 'a') as f:
                f.write(json.dumps(debug_data)+'\n')
        except Exception as e2:
            logger.warning(f"[DEBUG] Failed to write log file: {e2}")
        # #endregion
        logger.error(f"[{request_id}] worker error {e.response.status_code}: {response_text}")
        raise HTTPException(status_code=502, detail=f"Worker HTTP error {e.response.status_code}: {response_text[:100]}")

    except Exception as e:
        # #region agent log
        debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"B","location":"router.py:163","message":"Worker exception","data":{"exception_type":type(e).__name__,"exception_msg":str(e),"worker_url":WORKER_URL},"timestamp":int(time.time()*1000)}
        logger.error(f"[DEBUG] {json.dumps(debug_data)}")
        try:
            with open('/tmp/debug.log', 'a') as f:
                f.write(json.dumps(debug_data)+'\n')
        except Exception as e2:
            logger.warning(f"[DEBUG] Failed to write log file: {e2}")
        # #endregion
        logger.exception(f"[{request_id}] worker failed: {e}")
        raise HTTPException(status_code=502, detail=f"Worker error: {str(e)}")

    latency = time.time() - start
    ROUTER_LATENCY.observe(latency)
    # #region agent log
    debug_data = {"sessionId":"debug-session","runId":"run1","hypothesisId":"C","location":"router.py:99","message":"Router returning data","data":{"latency":latency,"data_type":type(data).__name__},"timestamp":int(time.time()*1000)}
    logger.info(f"[DEBUG] {json.dumps(debug_data)}")
    try:
        with open('/tmp/debug.log', 'a') as f:
            f.write(json.dumps(debug_data)+'\n')
    except Exception as e:
        logger.warning(f"[DEBUG] Failed to write log file: {e}")
    # #endregion
    logger.info(f"[{request_id}] done in {latency:.3f}s")
    return data
