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
import os
import time
import logging

# Initialize Flask app
app = Flask(__name__)

# The page lives next to this file (works in the container and in tests).
INDEX_HTML = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app', 'index.html')


def app_version():
    """Version baked into the image at build time (Docker build arg APP_VERSION)."""
    return os.environ.get('APP_VERSION', 'dev')


def error_simulation_enabled():
    """Fault injection for demos. On only where ERROR_SIMULATION=on (preprod overlay); never in prod."""
    return os.environ.get('ERROR_SIMULATION', 'off') == 'on'


# Shown on the page only when error simulation is on. Requests go from the browser to this app,
# so the errors are real 500s that count against the SLO and should fire the burn-rate alert.
SIMULATION_PANEL = """
<section style="margin-top:2em;padding:1em;border:2px dashed #b83232;max-width:40em">
  <h2>Fault injection (preprod only)</h2>
  <p>Sends requests from this browser. 500s count against this environment's SLO;
     the fast-burn alert should email within about 3 minutes.</p>
  <button onclick="send('/simulate-error', 50)">Send 50 errors</button>
  <button onclick="send('/version', 50)">Send 50 normal requests</button>
  <p id="sim-result"></p>
  <script>
    async function send(path, n) {
      const count = {};
      for (let i = 0; i < n; i++) {
        try { const r = await fetch(path, {cache: 'no-store'}); count[r.status] = (count[r.status] || 0) + 1; }
        catch (e) { count.failed = (count.failed || 0) + 1; }
        document.getElementById('sim-result').textContent =
          Object.entries(count).map(([k, v]) => v + ' x ' + k).join(', ') + '  (' + (i + 1) + '/' + n + ')';
      }
    }
  </script>
</section>
"""

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
    with open(INDEX_HTML, 'r') as f:
        html_content = f.read()
    panel = SIMULATION_PANEL if error_simulation_enabled() else ''
    html_content = html_content.replace('__APP_VERSION__', app_version()).replace('__SIMULATION__', panel)
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
    return Response(app_version(), status=200, mimetype='text/plain')

@app.route('/simulate-error', methods=['GET'])
def simulate_error():
    """Demo fault injection: a deliberate 500, only where the switch is on. Elsewhere it doesn't exist (404)."""
    if not error_simulation_enabled():
        return not_found(None)
    return Response('Simulated failure', status=500, mimetype='text/plain')

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
