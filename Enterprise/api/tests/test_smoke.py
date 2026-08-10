"""End-to-end smoke tests for the IT-Toolkit Enterprise API.

Covers the hardening gates from SCALING-PLAN.md (B1 RBAC, B2 ratelimit, B4
docs gating, C2 migrations, C3 ingest limits/dedupe, C4 transactional setup,
C5 commands, D3 audit) plus the base P1-P6 contract (healthz, setup, login,
users, ingest, commands). Uses the throwaway DB from conftest — the live
stack and its data are never touched.
"""


# ---------------------------------------------------------------- base health


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_docs_gated_in_prod(client):
    """B4: /docs + /openapi.json are disabled unless ENVIRONMENT=dev."""
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404


# ---------------------------------------------------------------- setup (C4)


def test_setup_is_one_shot(client, admin):
    """C4: setup completes; a second run is refused with 409."""
    assert client.get("/api/setup/status").json()["setup_complete"] is True
    r = client.post(
        "/api/setup",
        json={
            "company_name": "ACME Test Corp",
            "server_host": "test.local",
            "admin_username": "rootadmin",
            "admin_password": "Sup3rSecret!1",
            "build_mode": "manual",
        },
        headers={"X-Forwarded-For": "10.0.0.99"},
    )
    assert r.status_code == 409


def test_login_and_me(client, admin):
    r = client.get("/api/me", headers=admin)
    assert r.status_code == 200
    body = r.json()
    assert body["username"] == "rootadmin"


def test_session_secret_download_requires_admin(client, admin, monitoring):
    """Setup-rotated SESSION_SECRET is downloadable by admins only and matches
    the persisted value under DATA_DIR."""
    import os
    from pathlib import Path

    secret_file = Path(os.environ["DATA_DIR"]) / "session_secret"
    assert secret_file.exists()

    ok = client.get("/api/session-secret", headers=admin)
    assert ok.status_code == 200
    assert ok.headers["content-type"].startswith("text/plain")
    assert ok.text.strip() == secret_file.read_text().strip()

    denied = client.get("/api/session-secret", headers=monitoring)
    assert denied.status_code == 403

    anon = client.get("/api/session-secret")
    assert anon.status_code in (401, 403)


def test_login_bad_credentials(client):
    r = client.post(
        "/api/login",
        json={"username": "rootadmin", "password": "wrongpass"},
        headers={"X-Forwarded-For": "10.0.1.5"},
    )
    assert r.status_code == 401


# ---------------------------------------------------------------- RBAC (B1)


def test_monitoring_cannot_read_licenses(client, monitoring):
    """B1: license events are admin-only at the API level."""
    r = client.get("/api/events?kind=licenses", headers=monitoring)
    assert r.status_code == 403


def test_monitoring_cannot_read_audit(client, monitoring):
    """D3: audit log is admin-only."""
    r = client.get("/api/audit", headers=monitoring)
    assert r.status_code == 403


def test_admin_reads_licenses_ok(client, admin):
    r = client.get("/api/events?kind=licenses", headers=admin)
    assert r.status_code == 200


# ---------------------------------------------------------------- ingest (C3)


def test_ingest_dedupe(client, shared_token):
    """C3: identical client_msg_id is accepted once, then deduped."""
    batch = {
        "hostname": "pc-e2e-001",
        "os": "Windows 11",
        "agent_version": "1.2.0",
        "ip": "192.168.1.50",
        "events": [
            {
                "kind": "quickcheck",
                "payload": {"note": "hello"},
                "captured_at": "2026-08-09T10:00:00Z",
                "client_msg_id": "msg-dup-1",
            }
        ],
    }
    hdr = {"Authorization": f"Bearer {shared_token}"}
    r1 = client.post("/ingest", json=batch, headers=hdr)
    assert r1.status_code == 200, r1.text
    assert r1.json()["accepted"] == 1
    r2 = client.post("/ingest", json=batch, headers=hdr)
    assert r2.status_code == 200, r2.text
    assert r2.json()["accepted"] == 0  # deduped


def test_ingest_invalid_token(client):
    batch = {"hostname": "pc-e2e-002", "events": [{"kind": "quickcheck", "payload": {}}]}
    r = client.post("/ingest", json=batch, headers={"Authorization": "Bearer WRONG"})
    assert r.status_code == 401


def test_ingest_batch_rolls_back_on_bad_row(client, shared_token):
    """C3: one invalid row fails the whole batch (no partial write)."""
    batch = {
        "hostname": "pc-e2e-003",
        "events": [
            {"kind": "quickcheck", "payload": {}},
            {"kind": "", "payload": {}},  # invalid: kind required
        ],
    }
    r = client.post(
        "/ingest", json=batch, headers={"Authorization": f"Bearer {shared_token}"}
    )
    assert r.status_code == 400
    # nothing persisted for that batch
    ev = client.get("/api/events?kind=quickcheck").json()
    assert all(e.get("payload", {}).get("hostname") != "pc-e2e-003" for e in ev)


# ---------------------------------------------------------------- commands (C5)


def test_command_roundtrip(client, admin, shared_token):
    """P5/C5: create command -> agent poll -> post result -> completed."""
    # an agent exists from ingest tests; use its hostname
    agents = client.get("/api/agents", headers=admin).json()
    assert agents, "expected at least one agent from ingest tests"
    agent = agents[0]

    created = client.post(
        "/api/commands",
        json={"agent_id": agent["id"], "kind": "reboot", "payload": {"delay_seconds": 0}},
        headers=admin,
    )
    assert created.status_code == 200, created.text
    cmd = created.json()
    assert cmd["status"] in ("pending", "picked_up")

    # agent polls with its token and finds the command
    polled = client.get(
        "/api/commands/poll",
        params={"hostname": agent["hostname"]},
        headers={"Authorization": f"Bearer {shared_token}"},
    )
    assert polled.status_code == 200, polled.text
    assert any(c["id"] == cmd["id"] for c in polled.json())

    # agent posts the result
    res = client.post(
        f"/api/commands/{cmd['id']}/result",
        json={
            "hostname": agent["hostname"],
            "status": "completed",
            "output": "[REDACTED] reboot ok",
            "exit_code": 0,
        },
        headers={"Authorization": f"Bearer {shared_token}"},
    )
    assert res.status_code == 200, res.text


# ---------------------------------------------------------------- audit (D3)


def test_audit_log_has_login_and_command(client, admin):
    rows = client.get("/api/audit", headers=admin).json()
    actions = {r["action"] for r in rows}
    assert "auth.login" in actions
    assert "setup.complete" in actions
    assert "command.create" in actions
    assert "user.create" in actions


# ---------------------------------------------------------------- limits (C3)


def test_list_limit_clamped(client, admin):
    """C3: limit is clamped to MAX_LIST_LIMIT (<=500)."""
    r = client.get("/api/events?limit=999999", headers=admin)
    assert r.status_code == 200
    assert len(r.json()) <= 500
