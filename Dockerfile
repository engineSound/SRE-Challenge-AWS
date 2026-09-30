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

# Health check (python:3.11-slim has no curl, so use Python itself).
# Kubernetes uses its own probes; this one helps with plain `docker run`.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost/health', timeout=2).status == 200 else 1)"

# Run with gunicorn (production WSGI server)
CMD ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "4", "--timeout", "30", "app:app"]