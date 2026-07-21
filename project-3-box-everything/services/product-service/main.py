from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Product Service")


class Product(BaseModel):
    id: int
    name: str
    price_usd: float
    in_stock: bool


PRODUCTS = {
    1: Product(id=1, name="Mechanical Keyboard", price_usd=89.99, in_stock=True),
    2: Product(id=2, name="4K Monitor", price_usd=349.00, in_stock=True),
    3: Product(id=3, name="USB-C Hub", price_usd=24.50, in_stock=False),
}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/products")
def list_products():
    return list(PRODUCTS.values())


@app.get("/products/{product_id}")
def get_product(product_id: int):
    product = PRODUCTS.get(product_id)
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    return product
