from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi import Response
from typing import Union
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.middleware.base import BaseHTTPMiddleware
from logger import logger
import time

from database import get_items, insert_item

app = FastAPI()

# Prometheus metrics
REQUEST_COUNT = Counter("api_requests_total", "Total HTTP requests", ["method", "endpoint", "status"])
REQUEST_LATENCY = Histogram("api_request_duration_seconds", "Request Latency", ["endpoint"], buckets=(0.1, 0.3, 0.5, 0.7, 1, 1.5, 2, 3, 5, 10))
ERROR_COUNT = Counter("api_errors_total","Total 500 errors")
EXCLUDED_PATHS = {"/metrics", "/health"}

# Middleware to track request metrics
class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        start_time = time.time()
        response = None
        try:
            response = await call_next(request)
            return response
        except Exception: 
            raise
        finally:
            path = request.url.path
            if path not in EXCLUDED_PATHS: 
                process_time = time.time() - start_time
                REQUEST_LATENCY.labels(endpoint=request.url.path).observe(process_time)
                status = getattr(response, "status_code", 500)
                REQUEST_COUNT.labels(method=request.method, endpoint=path, status=str(status)).inc()
        return response

app.add_middleware(MetricsMiddleware)

# Handling Errors
@app.exception_handler(Exception)
async def exception_handler(request: Request, exc: Exception):
    ERROR_COUNT.inc()
    return JSONResponse(
        status_code=500,
        content={"error": "Internal Server Error", "detail": str(exc)}
    )

class ItemIn(BaseModel):
    name: str
    value: Union[float, int]

# / Health check endpoint
@app.get("/health")
def health():
    logger.info("Health check endpoint called")
    return {"status": "ok"}

# /items endpoint (GET & POST)
@app.get("/items")
def read_items():
    items = get_items()
    return {"items": items}

@app.post("/items")
def create_item(item: ItemIn):
    insert_item(item)
    return {"message": "Item created successfully"}

# /errors endpoint to simulate an alert
@app.get("/error")
def trigger_error():
    raise HTTPException(status_code=500, detail="Intentional error for alerting")

#/metrics endpoint for Prometheus
@app.get("/metrics")
def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

