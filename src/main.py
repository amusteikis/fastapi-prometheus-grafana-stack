from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from typing import Union
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response
import time

from database import get_items, insert_item

app = FastAPI()

# Prometheus metrics
REQUEST_COUNT = Counter(
    "api_requests_total", "Total HTTP requests", ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram(
    "api_request_duration_seconds",
    "Request Latency",
    ["endpoint"],
    buckets=(0.1, 0.3, 0.5, 0.7, 1, 1.5, 2, 3, 5, 10),
)
ERROR_COUNT = Counter("api_errors_total", "Total 500 errors")

EXCLUDED_PATHS = {"/metrics", "/health"}

# Middleware to track request metrics
class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        start_time = time.time()
        response: Response | None = None
        errored: bool = False

        try:
            response = await call_next(request)
            return response
        except Exception:
            errored = True
            raise
        finally:
            path = request.url.path
            if path not in EXCLUDED_PATHS:
                process_time = time.time() - start_time
                REQUEST_LATENCY.labels(endpoint=path).observe(process_time)

                status = 500 if errored or response is None else getattr(response, "status_code", 500)

                if 500 <= status < 600:
                    ERROR_COUNT.inc()

                REQUEST_COUNT.labels(
                    method=request.method, endpoint=path, status=str(status)
                ).inc()

app.add_middleware(MetricsMiddleware)

# Handling Errors (no contamos aquí para no duplicar)
@app.exception_handler(Exception)
async def exception_handler(request: Request, exc: Exception):
    return JSONResponse(
        status_code=500,
        content={"error": "Internal Server Error", "detail": str(exc)},
    )

class ItemIn(BaseModel):
    name: str
    value: Union[float, int]

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/items")
def read_items():
    items = get_items()
    return {"items": items}

@app.post("/items")
def create_item(item: ItemIn):
    insert_item(item)
    return {"message": "Item created successfully"}

@app.get("/error")
def trigger_error():
    raise HTTPException(status_code=500, detail="Intentional error for alerting")

@app.get("/metrics")
def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/boom")
def boom():
    raise HTTPException(status_code=500, detail="Boom")

@app.get("/boom-unhandled")
def boom_unhandled():
    1 / 0