# SRE Challenge - Flask App with Prometheus Metrics
FROM python:3.11-slim

# Links the image in GitHub's registry (GHCR) to this repository.
LABEL org.opencontainers.image.source="https://github.com/engineSound/SRE-Challenge-AWS"

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy app files
COPY app ./app
COPY app.py .

# Version shown by /version and the page; CI passes the image tag (e.g. sha-1a2b3c4).
# Declared after pip install so changing it doesn't invalidate the dependency layer.
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

# Health check (python:3.11-slim has no curl, so use Python itself).
# Kubernetes uses its own probes; this one helps with plain `docker run`.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost/health', timeout=2).status == 200 else 1)"

# Run with gunicorn: ONE worker process with 4 threads. prometheus_client keeps counters
# per process, so several worker processes would each report different counts and
# Prometheus would see fake counter resets. Scale out with more pods (HPA) instead.
CMD ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "1", "--threads", "4", "--timeout", "30", "app:app"]