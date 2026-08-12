"""Phase A: real-time metrics time-series tests.

Covers the metrics ingestion path (kind=metrics events -> the ``metrics``
table, NOT ``events``), the read endpoints (latest / keys / series with range
granularity), company scoping, dedup, and the rollup/retention task
(backfill -> hour/day buckets -> raw purge).
"""

from datetime import datetime, timedelta, timezone

import asyncpg
import json

from app import config, timeseries


# ---------------------------------------------------------------- helpers


def _ingest_metrics(client, shared_token, hostname, events):
    """POST a metrics batch and return the response."""
    batch = {
        "hostname": hostname,
        "os": "Windows 11",
        "agent_version": "1.2.0",
        "ip": "192.168.10.7",
        "events": events,
    }
    return client.post(
        "/ingest", json=batch, headers={"Authorization": f"Bearer {shared_token}"}
    )


def _sample(cpu, mem, client_msg_id, captured_at):
    """A canonical metrics sample payload."""
    return {
        "kind": "metrics",
        "client_msg_id": client_msg_id,
        "captured_at": captured_at,
        "payload": {
            "cpu": cpu,
            "mem_pct": mem,
            "disks": [{"drive": "C:", "total_gb": 512, "free_gb": 200,
                       "used_pct": 61, "read_bps": 1000, "write_bps": 500}],
            "net": [{"iface": "Ethernet0", "rx_bps": 20480, "tx_bps": 10240}],
            "battery_pct": 78,
            "battery_status": "on-ac",
        },
    }


def _agent_id(client, admin, hostname):
    agents = client.get("/api/agents", headers=admin).json()
    match = [a for a in agents if a["hostname"] == hostname]
    assert match, f"agent {hostname} not registered"
    return match[0]["id"]


# ---------------------------------------------------------------- ingestion


def test_metrics_ingest_row_counts(client, admin, shared_token):
    hn = "pc-metrics-001"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    r1 = _ingest_metrics(client, shared_token, hn, [_sample(12.5, 40.0, "m-1", now)])
    assert r1.status_code == 200, r1.text
    assert r1.json()["accepted"] == 1
    r2 = _ingest_metrics(client, shared_token, hn, [_sample(12.5, 40.0, "m-1", now)])
    assert r2.status_code == 200, r2.text
    assert r2.json()["accepted"] == 0  # deduped by client_msg_id

    # metrics rows must NOT leak into the events feed
    ev = client.get("/api/events?kind=metrics", headers=admin).json()
    assert ev == [], "metrics samples must not be stored as events"

    aid = _agent_id(client, admin, hn)
    latest = client.get(f"/api/agents/{aid}/metrics/latest", headers=admin)
    assert latest.status_code == 200, latest.text
    body = latest.json()
    assert body["hostname"] == hn
    assert body["payload"]["cpu"] == 12.5
    assert body["payload"]["battery_status"] == "on-ac"


def test_metrics_read_endpoints(client, admin, monitoring, shared_token):
    hn = "pc-metrics-002"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    r = _ingest_metrics(
        client, shared_token, hn,
        [_sample(80.0, 65.0, "m-2a", now), _sample(81.0, 66.0, "m-2b", now)],
    )
    assert r.status_code == 200, r.text
    aid = _agent_id(client, admin, hn)

    keys = client.get(f"/api/agents/{aid}/metrics/keys", headers=admin)
    assert keys.status_code == 200, keys.text
    kset = set(keys.json()["keys"])
    assert "cpu" in kset and "mem_pct" in kset
    assert "disk_used_pct:C:" in kset
    assert "net_rx_bps:Ethernet0" in kset

    series = client.get(f"/api/agents/{aid}/metrics?range=1h", headers=admin)
    assert series.status_code == 200, series.text
    body = series.json()
    assert body["granularity"] == "raw"
    assert isinstance(body["points"], list) and len(body["points"]) >= 1
    assert "avg" in body["points"][0] and body["points"][0]["avg"].get("cpu") is not None

    # monitoring role is read-only but may view metrics
    sm = client.get(f"/api/agents/{aid}/metrics?range=24h", headers=monitoring)
    assert sm.status_code == 200, sm.text
    # cross-company / unknown ids 404
    assert client.get("/api/agents/999999/metrics", headers=admin).status_code == 404


# ---------------------------------------------------------------- rollup + retention


def test_rollup_and_retention(client, admin, shared_token):
    import asyncio

    hn = "pc-metrics-003"
    ts1 = (datetime.now(timezone.utc) - timedelta(hours=26)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    ts2 = (datetime.now(timezone.utc) - timedelta(hours=26, minutes=5)).strftime(
        "%Y-%m-%dT%H:%M:%S.%fZ"
    )
    r = _ingest_metrics(
        client, shared_token, hn,
        [_sample(30.0, 50.0, "m-3a", ts1), _sample(45.0, 60.0, "m-3b", ts2)],
    )
    assert r.status_code == 200, r.text
    aid = _agent_id(client, admin, hn)

    async def _run():
        pool = await asyncpg.create_pool(
            config.DATABASE_URL, min_size=1, max_size=2,
            init=lambda conn: conn.set_type_codec(
                "jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog",
            ),
        )
        try:
            await timeseries.rollup_once(pool, config)

            hours = await pool.fetch(
                "SELECT * FROM metrics_rollup WHERE agent_id = $1 AND granularity = 'hour'",
                aid,
            )
            assert hours, "hour rollup must exist after rollup_once for past samples"
            days = await pool.fetch(
                "SELECT * FROM metrics_rollup WHERE agent_id = $1 AND granularity = 'day'",
                aid,
            )
            assert days, "day rollup must be promoted from hour rows"
            assert hours[0]["avg"].get("cpu") and hours[0]["samples"] >= 1

            # retention: force raw purge and confirm raw rows are gone
            raw_before = await pool.fetchval(
                "SELECT count(*) FROM metrics WHERE agent_id = $1", aid
            )
            assert raw_before >= 1
            saved_retention = config.TS_RAW_RETENTION_HOURS
            config.TS_RAW_RETENTION_HOURS = 0
            try:
                await timeseries.rollup_once(pool, config)
            finally:
                config.TS_RAW_RETENTION_HOURS = saved_retention
            raw_after = await pool.fetchval(
                "SELECT count(*) FROM metrics WHERE agent_id = $1", aid
            )
            assert raw_after == 0, "raw samples older than retention must be purged"
        finally:
            await pool.close()

    asyncio.run(_run())