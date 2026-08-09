"""Pytest fixtures for the IT-Toolkit Enterprise API test suite.

Tests run against a THROWAWAY Postgres database (``ittoolkit_test``) so the
live stack is never touched. The conftest:

1. Creates ``ittoolkit_test`` on the same Postgres server (needs CREATEDB,
   which the ittoolkit role has).
2. Points ``DATABASE_URL`` at it and imports the FastAPI app fresh.
3. Exposes a session-scoped ``client`` (httpx TestClient) + helpers that run
   the first-time setup and log in as admin / monitoring.

Run (from inside the api container, or anywhere with the app importable):

    DATABASE_URL=postgresql://ittoolkit:CHANGE_ME@db:5432/ittoolkit \
        python -m pytest tests -q

The base DATABASE_URL is taken from the environment; only the database name
is swapped for the test one.
"""

import os
import re

import asyncpg
import pytest

BASE_URL = os.environ.get("DATABASE_URL", "postgresql://ittoolkit:change-me@db:5432/ittoolkit")
TEST_DB = "ittoolkit_test"

# test database lives on the same server, different db name
_M = re.match(r"^(postgres(?:ql)?://[^/]+)/(.+)$", BASE_URL)
TEST_URL = f"{_M.group(1)}/{TEST_DB}" if _M else BASE_URL

# Isolate DATA_DIR + secrets so the suite never touches the live volume.
TEST_DATA_DIR = "/tmp/ittk-test-data"

# Point config.PORTAL_DIR / FEATURES_FILE at the checkout rather than the
# container layout (/app/...) so the same suite runs in Docker and CI.
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
TEST_PORTAL_DIR = os.path.join(_REPO_ROOT, "Enterprise", "portal")
TEST_FEATURES_FILE = os.path.join(_REPO_ROOT, "Enterprise", "api", "features.json")


def _admin_connect() -> asyncpg.Connection:
    # connect to the maintenance DB (same server) to create/drop the test DB
    maint_url = f"{_M.group(1)}/postgres" if _M else BASE_URL
    return asyncpg.connect(maint_url)


async def _recreate_test_db():
    conn = await _admin_connect()
    try:
        await conn.execute(f'DROP DATABASE IF EXISTS "{TEST_DB}"')
        await conn.execute(f'CREATE DATABASE "{TEST_DB}"')
    finally:
        await conn.close()


@pytest.fixture(scope="session", autouse=True)
def _test_db():
    """Create the throwaway DB once per session, drop it at the end."""
    import asyncio

    asyncio.run(_recreate_test_db())
    yield
    asyncio.run(_recreate_test_db())  # drop + recreate leaves a clean slate


# ---- point the app at the test DB BEFORE importing it ----------------------
os.environ["DATABASE_URL"] = TEST_URL
os.environ["DATA_DIR"] = TEST_DATA_DIR
os.environ["PORTAL_DIR"] = TEST_PORTAL_DIR
os.environ["FEATURES_FILE"] = TEST_FEATURES_FILE
os.environ["API_TOKEN"] = "test-shared-fleet-token-0001"
os.environ["SESSION_SECRET"] = "test-session-secret-0001"
os.environ["ENVIRONMENT"] = "prod"  # B4: docs gated by default in tests
os.environ["ALERT_EVAL_MINUTES"] = "60"  # keep the background loop quiet

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


@pytest.fixture(scope="session")
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="session")
def shared_token():
    return os.environ["API_TOKEN"]


def _login(client: TestClient, username: str, password: str) -> dict:
    r = client.post(
        "/api/login",
        json={"username": username, "password": password},
        headers={"X-Forwarded-For": "10.0.0.99"},
    )
    assert r.status_code == 200, r.text
    return {"X-Forwarded-For": "10.0.0.99", "Cookie": f"itk_session={r.cookies['itk_session']}"}


@pytest.fixture(scope="session")
def admin(client: TestClient):
    """First-time setup + admin login, once per session."""
    st = client.get("/api/setup/status").json()
    if not st.get("setup_complete"):
        r = client.post(
            "/api/setup",
            json={
                "company_name": "ACME Test Corp",
                "server_host": "test.local",
                "admin_username": "rootadmin",
                "admin_password": "Sup3rSecret!1",
                "build_mode": "manual",
                "smtp": None,
            },
            headers={"X-Forwarded-For": "10.0.0.99"},
        )
        assert r.status_code == 200, r.text
    return _login(client, "rootadmin", "Sup3rSecret!1")


@pytest.fixture(scope="session")
def monitoring(client: TestClient, admin):
    """A read-only monitoring user + login cookie."""
    r = client.post(
        "/api/users",
        json={"username": "monitor", "password": "Mon1torPass!", "role": "monitoring"},
        headers=admin,
    )
    assert r.status_code in (200, 201), r.text
    return _login(client, "monitor", "Mon1torPass!")
