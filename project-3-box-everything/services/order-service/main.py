import os
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Order Service")

# Same code, different URLs depending on where it runs - this is the
# whole point of reading these from the environment instead of hardcoding
# them. Locally (docker-compose), Docker's built-in DNS resolves
# "user-service" to the right container - no IP addresses involved.
# On ECS, there's no docker-compose DNS, so these point at the ALB's
# path-based routes instead (the same ALB users hit from outside).
USER_SERVICE_URL = os.environ.get("USER_SERVICE_URL", "http://user-service:8000")
PRODUCT_SERVICE_URL = os.environ.get("PRODUCT_SERVICE_URL", "http://product-service:8000")

ORDERS = {}
next_order_id = 1


class OrderRequest(BaseModel):
    user_id: int
    product_id: int
    quantity: int = 1


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/orders")
def list_orders():
    return list(ORDERS.values())


@app.get("/orders/{order_id}")
def get_order(order_id: int):
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    return order


@app.post("/orders", status_code=201)
def create_order(req: OrderRequest):
    global next_order_id

    # Cross-service validation over HTTP - this is what "microservices"
    # actually means in practice: order-service doesn't know or care how
    # user-service stores its data, it just asks over the network and
    # trusts the answer.
    with httpx.Client(timeout=5.0) as client:
        try:
            user_resp = client.get(f"{USER_SERVICE_URL}/users/{req.user_id}")
        except httpx.RequestError as e:
            raise HTTPException(status_code=503, detail=f"user-service unreachable: {e}")
        if user_resp.status_code == 404:
            raise HTTPException(status_code=400, detail=f"user {req.user_id} does not exist")
        user_resp.raise_for_status()

        try:
            product_resp = client.get(f"{PRODUCT_SERVICE_URL}/products/{req.product_id}")
        except httpx.RequestError as e:
            raise HTTPException(status_code=503, detail=f"product-service unreachable: {e}")
        if product_resp.status_code == 404:
            raise HTTPException(status_code=400, detail=f"product {req.product_id} does not exist")
        product_resp.raise_for_status()

    product = product_resp.json()
    if not product["in_stock"]:
        raise HTTPException(status_code=400, detail=f"product {req.product_id} is out of stock")

    order = {
        "id": next_order_id,
        "user_id": req.user_id,
        "product_id": req.product_id,
        "quantity": req.quantity,
        "total_usd": round(product["price_usd"] * req.quantity, 2),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    ORDERS[next_order_id] = order
    next_order_id += 1
    return order
