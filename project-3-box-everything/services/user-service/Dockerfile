# ---- Stage 1: builder ----
# Why a separate stage? pip, build tools, and cached wheel files add
# ~150MB+ of stuff nothing at runtime actually needs. Building in one
# stage and copying ONLY the installed packages into a clean second stage
# keeps the final image small - smaller image = faster ECS task startup,
# faster ECR pulls, smaller attack surface.
FROM python:3.12-slim AS builder

WORKDIR /app
COPY requirements.txt .
# --user installs to /root/.local instead of system site-packages, which
# makes it trivial to copy just the installed packages (not pip itself,
# not build caches) into the final stage below.
RUN pip install --no-cache-dir --user -r requirements.txt

# ---- Stage 2: final runtime image ----
FROM python:3.12-slim

# Running as root inside a container is the same mistake as running as
# root on a real server - a container escape or app vulnerability
# shouldn't hand the attacker root. Create an unprivileged user instead.
RUN useradd --create-home --shell /bin/bash appuser
WORKDIR /app

COPY --from=builder /root/.local /home/appuser/.local
COPY . .
RUN chown -R appuser:appuser /app

ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONUNBUFFERED=1

USER appuser
EXPOSE 8000

# Docker's own healthcheck (used by `docker ps` / compose) - separate
# from, but consistent with, the ALB target group health check that AWS
# uses in ecs.tf. Same endpoint, two different systems checking it.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
