from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.middleware.base import BaseHTTPMiddleware
import time

from database import get_items, insert_item

app = FastAPI()

# Prometheus metrics
REQUEST_COUNT = Counter("api_requests_total", "Total HTTP requests", ["method", "endpoint"])
REQUEST_LATENCY = Histogram("api_request_duration_seconds", "Request Latency", ["endpoint"])
ERROR_COUNT = Counter("api_errors_total","Total 500 errors")

# Middleware to track request metrics
class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        start_time = time.time()
        try:
            response = await call_next(request)
        except Exception as e:
            ERROR_COUNT.inc()
            raise e
        process_time = time.time() - start_time
        REQUEST_LATENCY.labels(endpoint=request.url.path).observe(process_time)
        REQUEST_COUNT.labels(method=request.method, endpoint=request.url.path).inc()
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
# / Health check endpoint
@app.get("/health")
def health():
    return {"status": "ok"}

# /items endpoint (GET & POST)
@app.get("/items")
def read_items():
    items = get_items()
    return {"items": items}

@app.post("/items")
def create_item(item: dict):
    insert_item(item)
    return {"message": "Item created successfully"}

# /errors endpoint to simulate an alert
@app.get("/error")
def trigger_error():
    raise HTTPException(status_code=500, detail="Intentional error for alerting")

#/metrics endpoint for Prometheus
@app.get("/metrics")
def metrics():
    return JSONResponse(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)