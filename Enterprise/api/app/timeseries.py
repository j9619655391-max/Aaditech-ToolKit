"""Phase A: real-time metrics time-series — rollup, retention and querying.

The agent streams one JSONB sample per second-ish cadence into the ``metrics``
table via /ingest. Raw rows are cheap to insert but too voluminous to keep
forever, so a background task (``rollup_loop``) downsamples them into
``metrics_rollup`` buckets (hour, then day) and purges raw rows after
``TS_RAW_RETENTION_HOURS``. Long-range dashboard queries read the rollups so
7d/30d graphs stay cheap even as the raw table churns.

``flatten_payload`` turns the nested JSONB shape (arrays of drives/interfaces)
into a flat dict of numeric series (e.g. ``disk_used_pct:C``) so averages/maxes
and chart keys are uniform.
"""
import asyncio
import logging
from datetime import datetime, timedelta, timezone

logger = logging.getLogger("uvicorn.error")

SCALAR_KEYS = (
    "cpu", "mem_pct", "mem_used_gb", "mem_total_gb", "temp_celsius",
    "gpu_util", "gpu_vram_pct", "battery_pct",
)
DISK_KEYS = ("total_gb", "free_gb", "used_pct", "read_bps", "write_bps")
NET_KEYS = ("rx_bps", "tx_bps")

_ROLLUP_LOCK_ID = 0x4954544B  # "ITTK" — advisory lock ns for the rollup task


def flatten_payload(payload: dict) -> dict:
    """Flatten a metrics sample into {series_key: float}. Non-numeric values
    (status strings, nulls) are dropped. Drives/interfaces are prefixed so each
    becomes its own plotable series."""
    out: dict = {}
    if not isinstance(payload, dict):
        return out
    for key in SCALAR_KEYS:
        v = payload.get(key)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out[key] = float(v)
    for d in payload.get("disks") or []:
        if not isinstance(d, dict):
            continue
        tag = str(d.get("drive") or "?")
        for k in DISK_KEYS:
            v = d.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                out[f"disk_{k}:{tag}"] = float(v)
    for n in payload.get("net") or []:
        if not isinstance(n, dict):
            continue
        tag = str(n.get("iface") or "?")
        for k in NET_KEYS:
            v = n.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                out[f"net_{k}:{tag}"] = float(v)
    return out


# ---------------------------------------------------------------- rollup

def _bucket_start(ts: datetime, granularity: str) -> datetime:
    """Floor a timestamp to the start of its hour or day bucket (UTC)."""
    if granularity == "day":
        return datetime(ts.year, ts.month, ts.day, tzinfo=ts.tzinfo)
    return datetime(ts.year, ts.month, ts.day, ts.hour, tzinfo=ts.tzinfo)


async def _latest_hour_bucket(pool, agent_id: int) -> datetime | None:
    row = await pool.fetchrow(
        "SELECT max(bucket) AS m FROM metrics_rollup "
        "WHERE agent_id = $1 AND granularity = 'hour'",
        agent_id,
    )
    return row["m"] if row and row["m"] else None


async def _latest_day_bucket(pool, agent_id: int) -> datetime | None:
    row = await pool.fetchrow(
        "SELECT max(bucket) AS m FROM metrics_rollup "
        "WHERE agent_id = $1 AND granularity = 'day'",
        agent_id,
    )
    return row["m"] if row and row["m"] else None


async def _rollup_hour(pool, agent_id: int, bucket: datetime, end: datetime) -> None:
    """Aggregate raw metrics rows in [bucket, end) into one 'hour' row (+ its
    neighbours if the window already passed multiple hour boundaries)."""
    rows = await pool.fetch(
        "SELECT ts, payload FROM metrics "
        "WHERE agent_id = $1 AND ts >= $2 AND ts < $3 "
        "ORDER BY ts ASC",
        agent_id, bucket, end,
    )
    if not rows:
        return
    # group by hour bucket in case the window spans several
    groups: dict[datetime, list] = {}
    for r in rows:
        b = _bucket_start(r["ts"].astimezone(timezone.utc), "hour")
        groups.setdefault(b, []).append(flatten_payload(r["payload"]))

    now = datetime.now(timezone.utc)
    for b, flats in groups.items():
        avg, mx, mn = _aggregate(flats)
        b_aware = b if b.tzinfo else b.replace(tzinfo=timezone.utc)
        await pool.execute(
            "INSERT INTO metrics_rollup (agent_id, granularity, bucket, avg, max, min, samples) "
            "VALUES ($1, 'hour', $2, $3, $4, $5, $6) "
            "ON CONFLICT (agent_id, granularity, bucket) DO UPDATE SET "
            "  avg = excluded.avg, max = excluded.max, min = excluded.min, "
            "  samples = excluded.samples",
            agent_id, b_aware, avg, mx, mn, len(flats),
        )
    logger.debug("timeseries: rolled %s copies into hour buckets for agent %s up to %s",
                 len(rows), agent_id, now.isoformat())


async def _rollup_day(pool, agent_id: int, bucket: datetime, end: datetime) -> None:
    """Promote completed 'hour' rows into 'day' buckets."""
    rows = await pool.fetch(
        "SELECT bucket, avg, max, min FROM metrics_rollup "
        "WHERE agent_id = $1 AND granularity = 'hour' AND bucket >= $2 AND bucket < $3 "
        "ORDER BY bucket ASC",
        agent_id, bucket, end,
    )
    if not rows:
        return
    groups: dict[datetime, list] = {}
    for r in rows:
        b = _bucket_start(r["bucket"].astimezone(timezone.utc), "day")
        groups.setdefault(b, []).append((r["avg"], r["max"], r["min"]))

    for b, triples in groups.items():
        avgs, maxes, mins = zip(*triples) if triples else ([], [], [])
        avg = _mean_dicts(list(avgs))
        mx = _max_dicts(list(maxes))
        mn = _min_dicts(list(mins))
        b_aware = b if b.tzinfo else b.replace(tzinfo=timezone.utc)
        await pool.execute(
            "INSERT INTO metrics_rollup (agent_id, granularity, bucket, avg, max, min, samples) "
            "VALUES ($1, 'day', $2, $3, $4, $5, $6) "
            "ON CONFLICT (agent_id, granularity, bucket) DO UPDATE SET "
            "  avg = excluded.avg, max = excluded.max, min = excluded.min, "
            "  samples = excluded.samples",
            agent_id, b_aware, avg, mx, mn, len(triples),
        )


def _aggregate(flats: list[dict]) -> tuple[dict, dict, dict]:
    avg = _mean_dicts(flats)
    mx = _max_dicts(flats)
    mn = _min_dicts(flats)
    return avg, mx, mn


def _mean_dicts(flats: list[dict]) -> dict:
    out: dict = {}
    if not flats:
        return out
    keys = set().union(*[set(f.keys()) for f in flats])
    for k in keys:
        vals = [f[k] for f in flats if k in f and isinstance(f[k], (int, float))]
        if vals:
            out[k] = round(sum(vals) / len(vals), 3)
    return out


def _max_dicts(flats: list[dict]) -> dict:
    out: dict = {}
    keys = set().union(*[set(f.keys()) for f in flats]) if flats else set()
    for k in keys:
        vals = [f[k] for f in flats if k in f and isinstance(f[k], (int, float))]
        if vals:
            out[k] = round(max(vals), 3)
    return out


def _min_dicts(flats: list[dict]) -> dict:
    out: dict = {}
    keys = set().union(*[set(f.keys()) for f in flats]) if flats else set()
    for k in keys:
        vals = [f[k] for f in flats if k in f and isinstance(f[k], (int, float))]
        if vals:
            out[k] = round(min(vals), 3)
    return out


# ---------------------------------------------------------------- query

def choose_granularity(range_seconds: int, config) -> str:
    """Pick the data source for a requested window: raw rows for short windows
    (within raw retention), else hour/day rollups."""
    if range_seconds <= config.TS_RAW_RETENTION_HOURS * 3600:
        return "raw"
    if range_seconds <= config.TS_HOURLY_RETENTION_DAYS * 86400:
        return "hour"
    return "day"


def default_bucket(range_seconds: int, max_points: int) -> int:
    """Snap the default bucket so a window renders at ~max_points samples with
    clean intervals (1m/5m/10m/15m/30m/1h/2h/4h/8h/12h/1d)."""
    target = max(60, range_seconds / max(1, max_points))
    for snap in (60, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 43200, 86400):
        if snap >= target:
            return snap
    return 86400


async def query_series(pool, agent_id: int, start: datetime, end: datetime,
                       bucket: int, granularity: str) -> list[dict]:
    """Return downsampled points [{ts, avg, max, min}] for the window.

    raw:   bucket the actual samples in Python (accurate avg/max/min, and the
           window is capped by raw retention so row counts stay bounded).
    hour/day: read rollup rows and bucket them further in Python.
    """
    points: list[dict] = []
    if granularity == "raw":
        rows = await pool.fetch(
            "SELECT ts, payload FROM metrics "
            "WHERE agent_id = $1 AND ts >= $2 AND ts < $3 ORDER BY ts ASC",
            agent_id, start, end,
        )
        items = [{"ts": r["ts"], "avg": flatten_payload(r["payload"]),
                  "max": flatten_payload(r["payload"]), "min": flatten_payload(r["payload"])}
                 for r in rows]
        buckets = _bucket_items(items, bucket)
        for b in buckets:
            flats = [i["avg"] for i in buckets[b]]
            avg, mx, mn = _aggregate(flats)
            points.append({"ts": b, "avg": avg, "max": mx, "min": mn, "samples": len(flats)})
    else:
        rows = await pool.fetch(
            "SELECT bucket, avg, max, min, samples FROM metrics_rollup "
            "WHERE agent_id = $1 AND granularity = $2 AND bucket >= $3 AND bucket < $4 "
            "ORDER BY bucket ASC",
            agent_id, granularity, start, end,
        )
        items = [{"ts": r["bucket"], "avg": dict(r["avg"] or {}), "max": dict(r["max"] or {}),
                  "min": dict(r["min"] or {})} for r in rows]
        if bucket <= _find_bucket_gap(items, granularity):
            # caller wants finer than the source → no downsampling, pass through
            for it in items:
                points.append({"ts": it["ts"], "avg": it["avg"], "max": it["max"],
                               "min": it["min"], "samples": 1})
        else:
            buckets = _bucket_items(items, bucket)
            for b in buckets:
                avgs = [i["avg"] for i in buckets[b]]
                maxes = [i["max"] for i in buckets[b]]
                mins = [i["min"] for i in buckets[b]]
                points.append({"ts": b, "avg": _mean_dicts(avgs), "max": _max_dicts(maxes),
                               "min": _min_dicts(mins), "samples": len(buckets[b])})
    return points


def _find_bucket_gap(items: list[dict], granularity: str) -> int:
    """The native spacing of the source (1h hour-buckets, 1d day-buckets)."""
    return 3600 if granularity == "hour" else 86400


def _bucket_items(items: list[dict], bucket_seconds: int) -> dict:
    """Group items by floor(ts / bucket). Returns {bucket_ts: [item,...]}."""
    buckets: dict = {}
    for it in items:
        ts = it["ts"]
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        epoch = int(ts.timestamp())
        start = epoch - (epoch % bucket_seconds)
        b_ts = datetime.fromtimestamp(start, tz=timezone.utc)
        buckets.setdefault(b_ts, []).append(it)
    return buckets


# ---------------------------------------------------------------- retention + loop

async def _retention(pool, config) -> None:
    """Drop raw samples older than TS_RAW_RETENTION_HOURS and rollup buckets
    older than their day-based retention windows."""
    raw_cut = datetime.now(timezone.utc) - timedelta(hours=config.TS_RAW_RETENTION_HOURS)
    await pool.execute(
        "DELETE FROM metrics WHERE ts < $1", raw_cut,
    )
    hour_cut = datetime.now(timezone.utc) - timedelta(days=config.TS_HOURLY_RETENTION_DAYS)
    await pool.execute(
        "DELETE FROM metrics_rollup WHERE granularity = 'hour' AND bucket < $1", hour_cut,
    )
    day_cut = datetime.now(timezone.utc) - timedelta(days=config.TS_DAILY_RETENTION_DAYS)
    await pool.execute(
        "DELETE FROM metrics_rollup WHERE granularity = 'day' AND bucket < $1", day_cut,
    )


async def rollup_once(pool, config) -> None:
    """Roll raw metrics up to the end of the most recent COMPLETED hour/day for
    every agent (idempotent: resumes from the last rollup bucket, backfills any
    earlier raw samples, and never leaves raw data unrolled). Then enforce
    retention."""
    # serialize concurrent rollup_loop workers: take an advisory lock on a
    # dedicated connection held for the whole run (session-level, no txn needed)
    lock_conn = await pool.acquire()
    try:
        await lock_conn.execute("SELECT pg_advisory_lock($1)", _ROLLUP_LOCK_ID)
    except Exception:
        await pool.release(lock_conn)
        raise

    try:
        agents = await pool.fetch("SELECT id FROM agents")
        now = datetime.now(timezone.utc)

        for a in agents:
            agent_id = a["id"]
            first_raw = await pool.fetchval(
                "SELECT min(ts) FROM metrics WHERE agent_id = $1", agent_id,
            )
            last_hour = await _latest_hour_bucket(pool, agent_id)
            if last_hour:
                h_start = last_hour + timedelta(hours=1)
            elif first_raw:
                h_start = _bucket_start(first_raw.astimezone(timezone.utc), "hour")
            else:
                continue
            if h_start < now:
                await _rollup_hour(pool, agent_id, h_start, now)

            first_hour = await pool.fetchval(
                "SELECT min(bucket) FROM metrics_rollup "
                "WHERE agent_id = $1 AND granularity = 'hour'", agent_id,
            )
            last_day = await _latest_day_bucket(pool, agent_id)
            if last_day:
                d_start = last_day + timedelta(days=1)
            elif first_hour:
                d_start = _bucket_start(first_hour.astimezone(timezone.utc), "day")
            else:
                continue
            if d_start < now:
                await _rollup_day(pool, agent_id, d_start, now)
        await _retention(pool, config)
    finally:
        await lock_conn.execute("SELECT pg_advisory_unlock($1)", _ROLLUP_LOCK_ID)
        await pool.release(lock_conn)


async def rollup_loop() -> None:
    from . import config, db

    interval = max(config.TS_ROLLUP_MINUTES, 1) * 60
    while True:
        try:
            pool = await db.connect()
            await rollup_once(pool, config)
            logger.info("timeseries rollup complete")
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.error("timeseries rollup failed: %r", exc)
        await asyncio.sleep(interval)