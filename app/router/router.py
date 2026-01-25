# router/router.py

import os
import time
import httpx
import logging
from typing import Optional, Dict, List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
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

app = FastAPI(title="LLM Router")

# =====================
# Prometheus Metrics
# =====================
ROUTER_REQUESTS = Counter("router_requests_total", "Total router requests")
ROUTER_LATENCY = Histogram("router_latency_seconds", "Router latency")
WORKER_HEALTH = Gauge("router_worker_health", "Health of workers", ["worker"])

# ======================
# Worker Configuration
# ======================
class TritonModelConfig:
    """Triton 模型配置缓存"""
    def __init__(self):
        self.model_name: Optional[str] = None
        self.input_name: Optional[str] = None
        self.output_name: Optional[str] = None
        self.input_dtype: Optional[str] = None
        self.output_dtype: Optional[str] = None
        self.last_updated: float = 0
        self.config_valid: bool = False
    
    def to_dict(self):
        """转换为字典，用于调试"""
        return {
            "model_name": self.model_name,
            "input_name": self.input_name,
            "output_name": self.output_name,
            "input_dtype": self.input_dtype,
            "output_dtype": self.output_dtype,
            "last_updated": self.last_updated,
            "config_valid": self.config_valid
        }

class WorkerConfig:
    def __init__(self, url: str, worker_type: str, api_endpoint: str = None):
        self.url = url
        self.worker_type = worker_type  # "vllm" or "trt"
        self.api_endpoint = api_endpoint
        self.triton_config: Optional[TritonModelConfig] = None
        if worker_type == "trt":
            self.triton_config = TritonModelConfig()
        logger.info(f"Created worker config: type={worker_type}, url={url}, endpoint={api_endpoint}")
    
    def _get_default_endpoint(self):
        if self.worker_type == "vllm":
            return "/v1/completions"
        elif self.worker_type == "trt":
            # 会在发现模型后动态设置
            return None
        else:
            return "/generate"
    
    def to_dict(self):
        """转换为字典，用于调试"""
        result = {
            "url": self.url,
            "worker_type": self.worker_type,
            "api_endpoint": self.api_endpoint
        }
        if self.triton_config:
            result["triton_config"] = self.triton_config.to_dict()
        return result

def build_workers_list():
    """动态构建 worker 列表（使用 Kubernetes Service DNS）"""
    logger.info("Building workers list...")
    workers = []
    
    # vLLM Worker Service
    workers.append(WorkerConfig(
        url="http://vllm-worker-service.llm.svc.cluster.local:8002",
        worker_type="vllm",
        api_endpoint="/v1/completions"
    ))
    
    # TensorRT-LLM Worker Service
    workers.append(WorkerConfig(
        url="http://trt-worker-service.llm.svc.cluster.local:8003",
        worker_type="trt"
    ))
    
    logger.info(f"Built {len(workers)} workers: {[w.worker_type for w in workers]}")
    return workers

WORKERS = build_workers_list()

# ======================
# Triton Model Discovery
# ======================
async def discover_triton_models(worker: WorkerConfig) -> List[str]:
    """发现 Triton Server 中的可用模型"""
    logger.info(f"Discovering Triton models from {worker.url}...")
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{worker.url}/v2/models")
            resp.raise_for_status()
            data = resp.json()
            # Triton API 返回格式: {"models": ["model1", "model2", ...]}
            models = data.get("models", [])
            logger.info(f"Discovered {len(models)} Triton models: {models}")
            return models
    except httpx.TimeoutException as e:
        logger.error(f"Timeout while discovering Triton models from {worker.url}: {e}")
        return []
    except httpx.HTTPStatusError as e:
        logger.error(f"HTTP error while discovering Triton models: status={e.response.status_code}, {e}")
        return []
    except Exception as e:
        logger.error(f"Failed to discover Triton models from {worker.url}: {type(e).__name__}: {e}", exc_info=True)
        return []

async def get_triton_model_config(worker: WorkerConfig, model_name: str) -> Optional[Dict]:
    """获取 Triton 模型的配置信息"""
    logger.info(f"Getting Triton model config for '{model_name}' from {worker.url}...")
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{worker.url}/v2/models/{model_name}/config")
            resp.raise_for_status()
            config = resp.json()
            logger.info(f"Got Triton model config for '{model_name}': {config}")
            return config
    except httpx.TimeoutException as e:
        logger.error(f"Timeout while getting Triton model config for '{model_name}': {e}")
        return None
    except httpx.HTTPStatusError as e:
        logger.error(f"HTTP error while getting Triton model config: status={e.response.status_code}, {e}")
        return None
    except Exception as e:
        logger.error(f"Failed to get Triton model config for '{model_name}': {type(e).__name__}: {e}", exc_info=True)
        return None

async def initialize_triton_worker(worker: WorkerConfig):
    """初始化 Triton worker：发现模型并获取配置"""
    if worker.worker_type != "trt" or not worker.triton_config:
        logger.debug(f"Skipping initialization for non-Triton worker: {worker.worker_type}")
        return
    
    logger.info(f"Initializing Triton worker at {worker.url}...")
    
    # 1. 发现可用模型
    models = await discover_triton_models(worker)
    if not models:
        logger.warning(f"No models found in Triton worker at {worker.url}")
        return
    
    # 2. 使用第一个可用模型（或可以通过环境变量指定）
    model_name = models[0]
    logger.info(f"Using model '{model_name}' from discovered models: {models}")
    worker.triton_config.model_name = model_name
    
    # 3. 获取模型配置
    config = await get_triton_model_config(worker, model_name)
    if not config:
        logger.warning(f"Failed to get config for model '{model_name}'")
        return
    
    # 4. 解析配置，提取输入/输出信息
    inputs = config.get("input", [])
    outputs = config.get("output", [])
    
    logger.debug(f"Model '{model_name}' inputs: {inputs}, outputs: {outputs}")
    
    if inputs:
        worker.triton_config.input_name = inputs[0].get("name", "INPUT")
        worker.triton_config.input_dtype = inputs[0].get("data_type", "BYTES")
        logger.info(f"Model input: name={worker.triton_config.input_name}, dtype={worker.triton_config.input_dtype}")
    else:
        logger.warning(f"No inputs found in model config for '{model_name}'")
    
    if outputs:
        worker.triton_config.output_name = outputs[0].get("name", "OUTPUT")
        worker.triton_config.output_dtype = outputs[0].get("data_type", "BYTES")
        logger.info(f"Model output: name={worker.triton_config.output_name}, dtype={worker.triton_config.output_dtype}")
    else:
        logger.warning(f"No outputs found in model config for '{model_name}'")
    
    # 5. 设置 API endpoint
    worker.api_endpoint = f"/v2/models/{model_name}/infer"
    worker.triton_config.config_valid = True
    worker.triton_config.last_updated = time.time()
    
    logger.info(f"Successfully initialized Triton worker: model={model_name}, endpoint={worker.api_endpoint}, "
                f"input={worker.triton_config.input_name}, output={worker.triton_config.output_name}")

# ======================
# Startup Event: 初始化 Triton workers
# ======================
@app.on_event("startup")
async def startup_event():
    """应用启动时初始化 Triton workers"""
    logger.info("=" * 60)
    logger.info("Router starting up...")
    logger.info(f"Total workers: {len(WORKERS)}")
    for i, worker in enumerate(WORKERS):
        logger.info(f"  Worker {i+1}: {worker.worker_type} at {worker.url}")
    
    logger.info("Initializing Triton workers...")
    for worker in WORKERS:
        if worker.worker_type == "trt":
            await initialize_triton_worker(worker)
    
    logger.info("Router startup complete!")
    logger.info("=" * 60)

# Simple Round-Robin Routing
rr_index = 0
def pick_worker():
    """选择下一个 worker（Round-robin）"""
    global rr_index
    if not WORKERS:
        logger.error("No workers available!")
        raise HTTPException(status_code=503, detail="No workers available")
    worker = WORKERS[rr_index % len(WORKERS)]
    old_index = rr_index
    rr_index += 1
    logger.debug(f"Picked worker: index={old_index % len(WORKERS)} -> {worker.worker_type} at {worker.url}")
    return worker

def build_worker_request(worker: WorkerConfig, prompt: str, max_new_tokens: int, temperature: float):
    """根据 worker 类型构建不同的请求格式"""
    logger.debug(f"Building request for {worker.worker_type} worker: prompt_length={len(prompt)}, "
                f"max_tokens={max_new_tokens}, temperature={temperature}")
    
    if worker.worker_type == "vllm":
        # vLLM 使用 OpenAI API 格式 (/v1/completions)
        # 必须包含 "model" 字段，值为 vLLM worker 启动时指定的模型路径
        request = {
            "model": "qwen2.5-0.5b",
            "prompt": prompt,
            "max_tokens": max_new_tokens,
            "temperature": temperature
        }
        logger.debug(f"vLLM request: {request}")
        return request
    elif worker.worker_type == "trt":
        # TRT (Triton) 使用 Triton 格式
        if not worker.triton_config or not worker.triton_config.config_valid:
            logger.error("Triton worker not initialized!")
            raise HTTPException(
                status_code=503, 
                detail="Triton worker not initialized. Model discovery failed."
            )
        
        config = worker.triton_config
        request = {
            "inputs": [
                {
                    "name": config.input_name,
                    "shape": [1],
                    "datatype": config.input_dtype,
                    "data": [prompt]
                }
            ],
            "outputs": [{"name": config.output_name}]
        }
        logger.debug(f"Triton request: inputs={request['inputs']}, outputs={request['outputs']}")
        return request
    else:
        # 默认格式
        request = {
            "prompt": prompt,
            "max_new_tokens": max_new_tokens,
            "temperature": temperature
        }
        logger.debug(f"Default request: {request}")
        return request

def parse_worker_response(worker: WorkerConfig, response_data: dict):
    """根据 worker 类型解析不同的响应格式"""
    logger.debug(f"Parsing response from {worker.worker_type} worker: response_keys={list(response_data.keys())}")
    
    if worker.worker_type == "vllm":
        # vLLM OpenAI API 响应格式
        if "choices" in response_data and len(response_data["choices"]) > 0:
            output = response_data["choices"][0].get("text", "")
            logger.debug(f"vLLM response: output_length={len(output)}")
            return {"output": output}
        logger.warning("vLLM response has no choices!")
        return {"output": ""}
    elif worker.worker_type == "trt":
        # TRT (Triton) 响应格式
        if "outputs" in response_data and len(response_data["outputs"]) > 0:
            output_data = response_data["outputs"][0].get("data", [])
            if output_data:
                output = output_data[0] if isinstance(output_data, list) else output_data
                logger.debug(f"Triton response: output_length={len(str(output))}")
                return {"output": output}
        logger.warning("Triton response has no outputs!")
        return {"output": ""}
    else:
        # 默认格式
        logger.debug(f"Default response: {response_data}")
        return response_data

class GenerateRequest(BaseModel):
    prompt: str
    max_new_tokens: int = 64
    temperature: float = 0.7

@app.get("/health")
async def health():
    """健康检查，包含 worker 状态"""
    worker_status = []
    for worker in WORKERS:
        status = {
            "url": worker.url,
            "type": worker.worker_type,
            "endpoint": worker.api_endpoint
        }
        if worker.worker_type == "trt" and worker.triton_config:
            status["triton"] = {
                "model_name": worker.triton_config.model_name,
                "config_valid": worker.triton_config.config_valid,
                "last_updated": worker.triton_config.last_updated
            }
        worker_status.append(status)
    
    return {
        "status": "ok",
        "workers": worker_status,
        "worker_count": len(WORKERS)
    }

@app.get("/debug")
async def debug():
    """调试端点：查看详细的运行时状态"""
    debug_info = {
        "workers": [worker.to_dict() for worker in WORKERS],
        "rr_index": rr_index,
        "worker_count": len(WORKERS),
        "timestamp": time.time()
    }
    logger.info("Debug endpoint accessed")
    return debug_info

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/route_generate")
async def route_generate(req: GenerateRequest):
    request_id = f"req_{int(time.time() * 1000)}"
    logger.info(f"[{request_id}] Received route_generate request: prompt_length={len(req.prompt)}, "
                f"max_tokens={req.max_new_tokens}, temperature={req.temperature}")
    
    ROUTER_REQUESTS.inc()
    start_time = time.time()

    worker = pick_worker()
    logger.info(f"[{request_id}] Selected worker: {worker.worker_type} at {worker.url}")
    
    # 如果是 Triton worker 且未初始化，尝试初始化
    if worker.worker_type == "trt" and (not worker.triton_config or not worker.triton_config.config_valid):
        logger.warning(f"[{request_id}] Triton worker not initialized, attempting initialization...")
        await initialize_triton_worker(worker)
        if not worker.triton_config or not worker.triton_config.config_valid:
            logger.error(f"[{request_id}] Failed to initialize Triton worker!")
            raise HTTPException(
                status_code=503, 
                detail="Triton worker not available. Model discovery failed."
            )
    
    worker_request = build_worker_request(
        worker, 
        req.prompt, 
        req.max_new_tokens, 
        req.temperature
    )

    try:
        logger.info(f"[{request_id}] Sending request to {worker.url}{worker.api_endpoint}")
        async with httpx.AsyncClient(timeout=25.0) as client:
            resp = await client.post(
                f"{worker.url}{worker.api_endpoint}", 
                json=worker_request
            )
            resp.raise_for_status()
            response_data = resp.json()
            logger.info(f"[{request_id}] Received response: status={resp.status_code}, "
                       f"response_size={len(str(response_data))}")
    except httpx.TimeoutException as e:
        logger.error(f"[{request_id}] Timeout while calling worker: {e}")
        raise HTTPException(status_code=504, detail=f"Worker timeout: {str(e)}")
    except httpx.HTTPStatusError as e:
        logger.error(f"[{request_id}] HTTP error from worker: status={e.response.status_code}, "
                    f"response={e.response.text[:200]}")
        raise HTTPException(status_code=503, detail=f"Worker HTTP error: {e.response.status_code}")
    except Exception as e:
        logger.error(f"[{request_id}] Worker failed: {type(e).__name__}: {e}", exc_info=True)
        raise HTTPException(status_code=503, detail=f"Worker failed: {str(e)}")

    # 解析响应并统一格式
    parsed_response = parse_worker_response(worker, response_data)
    latency = time.time() - start_time
    ROUTER_LATENCY.observe(latency)
    
    logger.info(f"[{request_id}] Request completed: latency={latency:.3f}s, "
               f"output_length={len(parsed_response.get('output', ''))}")
    
    return parsed_response
