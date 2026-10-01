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
