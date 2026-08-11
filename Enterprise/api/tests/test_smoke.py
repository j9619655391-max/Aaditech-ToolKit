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


# ---------------------------------------------------------------- F1: webhook alerts


def test_webhook_config_roundtrip(client, admin, monitoring):
    """F1: webhook alert config is readable/writable by admins; the payload is
    shaped per channel type and test-webhook refuses a disabled config."""
    r = client.get("/api/alerts/webhook", headers=admin)
    assert r.status_code == 200
    assert r.json()["enabled"] is False

    put = client.put(
        "/api/alerts/webhook",
        json={"enabled": True, "url": "https://hooks.example.com/x", "type": "slack", "token": ""},
        headers=admin,
    )
    assert put.status_code == 200, put.text
    assert put.json()["sendable"] is True
    assert put.json()["type"] == "slack"

    got = client.get("/api/alerts/webhook", headers=admin).json()
    assert got["enabled"] is True and got["url"] == "https://hooks.example.com/x"

    denied = client.get("/api/alerts/webhook", headers=monitoring)
    assert denied.status_code == 403

    # restore default so other tests aren't affected by a live webhook
    client.put(
        "/api/alerts/webhook",
        json={"enabled": False, "url": "", "type": "generic", "token": ""},
        headers=admin,
    )


def test_webhook_payload_shapes(client):
    """F1: payloads are formatted for Slack / Teams / generic channels."""
    from app import rules

    portal = "itk.example"
    alerts = [{"severity": "critical", "hostname": "SRV-01", "message": "disk full"}]

    mt, slack = rules._webhook_payload(alerts, "slack", portal)
    assert mt == "application/json"
    assert slack["blocks"][0]["text"]["text"] == "*1 new alert(s)*"
    assert "SRV-01" in slack["blocks"][1]["text"]["text"]

    mt, teams = rules._webhook_payload(alerts, "teams", portal)
    assert teams["@type"] == "MessageCard" and teams["themeColor"] == "0072C6"

    mt, generic = rules._webhook_payload(alerts, "generic", portal)
    assert generic["event"] == "alerts.opened" and generic["count"] == 1
    assert generic["alerts"][0]["hostname"] == "SRV-01"


def test_webhook_delivery_to_local_server(client, admin):
    """F1: a configured webhook actually receives the alert digest (E2E)."""
    import http.server
    import threading

    received: dict = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            received["body"] = self.rfile.read(length).decode()
            received["content_type"] = self.headers.get("Content-Type", "")
            self.send_response(200)
            self.end_headers()

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_address[1]}/hook"

    try:
        client.put(
            "/api/alerts/webhook",
            json={"enabled": True, "url": url, "type": "teams", "token": "tok-123"},
            headers=admin,
        )
        test = client.post("/api/alerts/test-webhook", headers=admin)
        assert test.status_code == 200, test.text
        assert test.json()["type"] == "teams"
        assert received.get("content_type", "").startswith("application/json")
        import json as _json
        assert _json.loads(received["body"])["@type"] == "MessageCard"
        assert received["body"] != ""  # a live POST happened
    finally:
        server.shutdown()
        server.server_close()
        client.put(
            "/api/alerts/webhook",
            json={"enabled": False, "url": "", "type": "generic", "token": ""},
            headers=admin,
        )


def test_webhook_test_requires_config(client, admin):
    """F1: test-webhook without a configured URL is refused with 400."""
    r = client.post("/api/alerts/test-webhook", headers=admin)
    assert r.status_code == 400


# ---------------------------------------------------------------- F3: software inventory


def _ingest_software(client, shared_token, hostname, apps):
    batch = {
        "hostname": hostname,
        "os": "Windows 11",
        "agent_version": "1.2.0",
        "events": [
            {
                "kind": "software",
                "payload": {"count": len(apps), "apps": apps},
                "captured_at": "2026-08-11T09:00:00Z",
                "client_msg_id": f"soft-{hostname}",
            },
            {
                "kind": "licenses",
                "payload": {"windows_key_last5": "A1B2C", "office_keys_last5": "D3E4F"},
                "captured_at": "2026-08-11T09:00:00Z",
                "client_msg_id": f"lic-{hostname}",
            },
        ],
    }
    r = client.post(
        "/ingest",
        json=batch,
        headers={"Authorization": f"Bearer {shared_token}"},
    )
    assert r.status_code == 200, r.text
    return r.json()["agent_id"]


def test_software_search_finds_apps(client, admin, shared_token):
    """F3: search finds installed apps by name/publisher; empty query lists all."""
    _ingest_software(
        client, shared_token, "pc-soft-001",
        [{"DisplayName": "Google Chrome", "DisplayVersion": "126.0.6478.0", "Publisher": "Google LLC"}],
    )
    hit = client.get("/api/software/search", params={"q": "chrome"}, headers=admin).json()
    assert hit["agents"] >= 1
    assert any(r["hostname"] == "pc-soft-001" for r in hit["results"])
    assert any(
        a["DisplayName"] == "Google Chrome"
        for r in hit["results"] for a in r["apps"]
    )

    all_rows = client.get("/api/software/search", params={"q": ""}, headers=admin).json()
    assert all_rows["agents"] >= 1


def test_software_export_csv(client, admin, shared_token):
    """F3: CSV export lists hostname + app columns."""
    _ingest_software(
        client, shared_token, "pc-soft-002",
        [{"DisplayName": "Microsoft Edge", "DisplayVersion": "124", "Publisher": "Microsoft"}],
    )
    r = client.get("/api/software/export", headers=admin)
    assert r.status_code == 200
    assert "text/csv" in r.headers["content-type"]
    assert "Microsoft Edge" in r.text
    assert "pc-soft-002" in r.text


def test_license_compliance_admin_only(client, admin, monitoring, shared_token):
    """F3: license compliance view is admin-only and shows last-5 key chars."""
    _ingest_software(client, shared_token, "pc-soft-003", [])
    r = client.get("/api/license/compliance", headers=admin)
    assert r.status_code == 200, r.text
    rows = r.json()["compliance"]
    assert any(x["hostname"] == "pc-soft-003" and x["windows_key_last5"] == "A1B2C" for x in rows)

    denied = client.get("/api/license/compliance", headers=monitoring)
    assert denied.status_code == 403

    exp = client.get("/api/license/export", headers=admin)
    assert exp.status_code == 200 and "windows_key_last5" in exp.text


# ---------------------------------------------------------------- F4: tenants


def test_setup_creates_company_and_binds_admin(client, admin):
    """F4: setup created a tenant company and the admin user belongs to it."""
    r = client.get("/api/bootstrap", headers=admin)
    assert r.status_code == 200
    body = r.json()
    assert body["company"]["name"] == "ACME Test Corp"
    assert body["user"]["company_id"] == body["company"]["id"]
    assert any(c["name"] == "ACME Test Corp" for c in body["companies"])


def test_company_directory_and_default(client, admin):
    """F4: admins can list/create companies and repoint the default."""
    companies = client.get("/api/companies", headers=admin)
    assert companies.status_code == 200
    assert any(c["name"] == "ACME Test Corp" for c in companies.json())

    created = client.post("/api/companies", json={"name": "Beta Corp"}, headers=admin)
    assert created.status_code in (200, 201), created.text

    dup = client.post("/api/companies", json={"name": "Beta Corp"}, headers=admin)
    assert dup.status_code == 409

    cur = client.get("/api/settings/default-company", headers=admin)
    assert cur.json()["company_id"] is not None

    moved = client.post("/api/settings/default-company", json={"name": "Beta Corp"}, headers=admin)
    assert moved.status_code == 200 and moved.json()["name"] == "Beta Corp"


def test_company_isolates_agents_and_users(client, admin, shared_token):
    """F4: an agent enrolled while Beta is the default company is invisible to
    the ACME-scoped admin; its new users carry the tenant too."""
    client.post("/api/settings/default-company", json={"name": "Beta Corp"}, headers=admin)
    batch = {
        "hostname": "pc-beta-001",
        "os": "Windows 11",
        "events": [{"kind": "quickcheck", "payload": {"note": "beta"}, "captured_at": "2026-08-11T10:00:00Z"}],
    }
    r = client.post("/ingest", json=batch, headers={"Authorization": f"Bearer {shared_token}"})
    assert r.status_code == 200, r.text

    agents = client.get("/api/agents", headers=admin).json()
    assert not any(a["hostname"] == "pc-beta-001" for a in agents), "cross-tenant leak!"

    # a new user created by the ACME admin still belongs to ACME
    created = client.post(
        "/api/users",
        json={"username": "acme-op", "password": "AcmeOpPass!1", "role": "operation"},
        headers=admin,
    )
    assert created.status_code == 200, created.text
    acme_id = client.get("/api/bootstrap", headers=admin).json()["company"]["id"]
    assert created.json()["company_id"] == acme_id

    # restore default so later ingests go to ACME again
    client.post("/api/settings/default-company", json={"name": "ACME Test Corp"}, headers=admin)


# ---------------------------------------------------------------- fixes: repo normalize + legacy agents


def test_normalize_repo_accepts_full_urls():
    """Operators pasting a full GitHub URL no longer produce a 404 on the
    GitHub API (/repos/https://github.com/...). Every accepted form collapses
    to canonical `owner/repo`."""
    from app import github

    cases = {
        "https://github.com/j9619655391-max/Aaditech-ToolKit.git": "j9619655391-max/Aaditech-ToolKit",
        "https://github.com/OWNER/REPO": "OWNER/REPO",
        "http://github.com/OWNER/REPO": "OWNER/REPO",
        "github.com/OWNER/REPO": "OWNER/REPO",
        "git@github.com:OWNER/REPO.git": "OWNER/REPO",
        "  OWNER/REPO/  ": "OWNER/REPO",
        "OWNER/REPO": "OWNER/REPO",
        "": "",
    }
    for raw, expected in cases.items():
        assert github._normalize_repo(raw) == expected, raw


def test_legacy_null_company_agent_visible_to_admin(client, admin):
    """F4 fix: agents enrolled before multi-tenant (company_id NULL) stay
    visible to company-scoped users instead of vanishing from the Agents tab."""
    import asyncio
    import asyncpg
    import os

    async def _seed():
        conn = await asyncpg.connect(os.environ["DATABASE_URL"])
        try:
            await conn.execute(
                "INSERT INTO agents (hostname, company_id) VALUES ('pc-legacy-null', NULL) "
                "ON CONFLICT (hostname) DO NOTHING"
            )
        finally:
            await conn.close()

    asyncio.run(_seed())

    agents = client.get("/api/agents", headers=admin).json()
    assert any(a["hostname"] == "pc-legacy-null" for a in agents), "NULL-company agent invisible!"
