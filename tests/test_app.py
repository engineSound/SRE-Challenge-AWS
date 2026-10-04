"""Unit tests for the Flask app: the endpoints Kubernetes, Prometheus and users rely on."""
import importlib
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
app_module = importlib.import_module("app")


@pytest.fixture
def client():
    app_module.app.config["TESTING"] = True
    with app_module.app.test_client() as c:
        yield c


def test_health_is_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.data == b"OK"


def test_version_comes_from_build(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "sha-test123")
    r = client.get("/version")
    assert r.status_code == 200
    assert r.data == b"sha-test123"


def test_version_defaults_to_dev(client, monkeypatch):
    monkeypatch.delenv("APP_VERSION", raising=False)
    assert client.get("/version").data == b"dev"


def test_page_shows_answer_and_version(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "sha-test123")
    r = client.get("/")
    assert r.status_code == 200
    assert b"The answer is 42!" in r.data
    assert b"sha-test123" in r.data


def test_metrics_count_requests_by_endpoint_and_status(client):
    client.get("/health")
    client.get("/does-not-exist")
    body = client.get("/metrics").data.decode()
    assert 'http_requests_total{endpoint="/health",method="GET",status="200"}' in body
    assert 'status="404"' in body
    assert "http_request_duration_seconds_bucket" in body


def test_unknown_path_returns_404(client):
    assert client.get("/nope").status_code == 404


def test_error_simulation_off_by_default(client, monkeypatch):
    # Prod never sets the switch: the route behaves as if it doesn't exist and the page has no button.
    monkeypatch.delenv("ERROR_SIMULATION", raising=False)
    assert client.get("/simulate-error").status_code == 404
    page = client.get("/").data
    assert b"Send 50 errors" not in page
    assert b"__SIMULATION__" not in page


def test_error_simulation_on_returns_500_and_shows_button(client, monkeypatch):
    monkeypatch.setenv("ERROR_SIMULATION", "on")
    assert client.get("/simulate-error").status_code == 500
    page = client.get("/").data
    assert b"Send 50 errors" in page
    assert b"The answer is 42!" in page


def test_simulated_errors_are_counted_as_5xx(client, monkeypatch):
    # The SLO counts 5xx from http_requests_total, so simulated errors must show up there.
    monkeypatch.setenv("ERROR_SIMULATION", "on")
    client.get("/simulate-error")
    body = client.get("/metrics").data.decode()
    assert 'http_requests_total{endpoint="/simulate-error",method="GET",status="500"}' in body
