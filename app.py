#!/usr/bin/env python3
"""
SRE Challenge Flask App with Prometheus Metrics

This app:
- Serves the main page with version info
- Exposes Prometheus metrics on /metrics endpoint
- Tracks: request count, latency, errors
"""

from flask import Flask, Response, request, g
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import time
import logging

# Initialize Flask app
app = Flask(__name__)

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ============================================================================
# PROMETHEUS METRICS
# ============================================================================

# Counter: Total HTTP requests by status code
http_requests_total = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['status', 'method', 'endpoint']
)

# Histogram: Request duration in seconds (for latency tracking)
http_request_duration_seconds = Histogram(
    'http_request_duration_seconds',
    'HTTP request duration in seconds',
    ['method', 'endpoint'],
    buckets=(0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0)
)

# ============================================================================
# REQUEST MIDDLEWARE
# ============================================================================

@app.before_request
def before_request_metrics():
    """Store request start time for duration tracking"""
    g.start_time = time.time()

@app.after_request
def after_request_metrics(response):
    """Record metrics after each request"""
    if hasattr(g, 'start_time'):
        duration = time.time() - g.start_time
        http_request_duration_seconds.labels(
            method=request.method,
            endpoint=request.path
        ).observe(duration)

    # Record request counter
    http_requests_total.labels(
        status=response.status_code,
        method=request.method,
        endpoint=request.path
    ).inc()

    logger.info(f"{request.method} {request.path} - {response.status_code}")
    return response

# ============================================================================
# ROUTES
# ============================================================================

@app.route('/', methods=['GET'])
def index():
    """Main application endpoint - serves the app version info"""
    with open('/app/app/index.html', 'r') as f:
        html_content = f.read()
    return Response(html_content, mimetype='text/html')

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint for Kubernetes probes"""
    return Response('OK', status=200, mimetype='text/plain')

@app.route('/metrics', methods=['GET'])
def metrics():
    """Prometheus metrics endpoint"""
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

@app.route('/version', methods=['GET'])
def version():
    """Version endpoint"""
    return Response('v4.0', status=200, mimetype='text/plain')

# ============================================================================
# ERROR HANDLERS
# ============================================================================

@app.errorhandler(404)
def not_found(error):
    """Handle 404 errors"""
    return Response('Not Found', status=404, mimetype='text/plain')

@app.errorhandler(500)
def internal_error(error):
    """Handle 500 errors"""
    return Response('Internal Server Error', status=500, mimetype='text/plain')

# ============================================================================
# MAIN
# ============================================================================

if __name__ == '__main__':
    logger.info('Starting SRE Challenge Flask App with Prometheus metrics')
    logger.info('Metrics available at http://localhost:80/metrics')
    app.run(host='0.0.0.0', port=80, debug=False)
