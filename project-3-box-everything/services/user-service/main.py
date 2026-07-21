import json
import os

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="User Service")

# Redis is a nice-to-have cache, not a hard dependency. Locally (docker
# compose) REDIS_URL points at the redis container. On ECS Fargate no
# REDIS_URL is set at all - the service just runs with caching disabled
# instead of crashing on startup. This is the difference between a
# dependency and an optimization: losing an optimization should degrade
# performance, never take the service down.
REDIS_URL = os.environ.get("REDIS_URL")
_redis_client = None
if REDIS_URL:
    try:
        import redis

        _redis_client = redis.from_url(REDIS_URL, socket_connect_timeout=1, decode_responses=True)
        _redis_client.ping()
    except Exception:
        _redis_client = None


class User(BaseModel):
    id: int
    name: str
    email: str


USERS = {
    1: User(id=1, name="Ada Lovelace", email="ada@example.com"),
    2: User(id=2, name="Grace Hopper", email="grace@example.com"),
    3: User(id=3, name="Alan Turing", email="alan@example.com"),
}


@app.get("/health")
def health():
    return {"status": "ok", "cache": "connected" if _redis_client else "disabled"}


@app.get("/users")
def list_users():
    return list(USERS.values())


@app.get("/users/{user_id}")
def get_user(user_id: int):
    cache_key = f"user:{user_id}"
    if _redis_client:
        cached = _redis_client.get(cache_key)
        if cached:
            return json.loads(cached)

    user = USERS.get(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if _redis_client:
        _redis_client.setex(cache_key, 30, user.model_dump_json())

    return user
