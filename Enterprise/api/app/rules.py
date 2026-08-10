"""P6 alert rules: seeding + evaluation loop.

Rules are stored in alert_rules (jsonb condition). The eval loop runs on a
background asyncio task and, for each enabled rule + agent, opens an alert
once (when the condition fires and no 'open' alert exists for that pair) and
resolves open alerts when the condition clears.
"""
import asyncio
import json
import logging
import smtplib
import urllib.request

from datetime import datetime, timedelta, timezone
from email.message import EmailMessage

logger = logging.getLogger("uvicorn.error")

DEFAULT_RULES = [
    {
        "name": "agent-offline",
        "severity": "warning",
        "condition": {"kind": "offline", "minutes": 15},
        "description": "Agent has not reported within the given number of minutes.",
    },
    {
        "name": "disk-low",
        "severity": "warning",
        "condition": {"kind": "disk-low", "percent": 10},
        "description": "A logical disk has less than the given percent free.",
    },
    {
        "name": "smart-predict",
        "severity": "critical",
        "condition": {"kind": "smart-predict"},
        "description": "SMART predicts imminent disk failure.",
    },
    {
        "name": "battery-low",
        "severity": "warning",
        "condition": {"kind": "battery-low", "percent": 20},
        "description": "Battery charge is below the given percent.",
    },
    {
        "name": "service-down",
        "severity": "warning",
        "condition": {"kind": "service-down"},
        "description": "An auto-start critical service is stopped.",
    },
    {
        "name": "reboot-pending",
        "severity": "info",
        "condition": {"kind": "reboot-pending", "uptime_days": 7},
        "description": "A reboot is pending and uptime exceeds the given days.",
    },
]


async def seed_rules(pool) -> None:
    for rule in DEFAULT_RULES:
        row = await pool.fetchrow("SELECT id FROM alert_rules WHERE name = $1", rule["name"])
        if row is None:
            await pool.execute(
                "INSERT INTO alert_rules (name, description, condition, severity) "
                "VALUES ($1, $2, $3, $4)",
                rule["name"], rule["description"], rule["condition"], rule["severity"],
            )


async def _latest_payload(pool, agent_id: int, kind: str) -> dict | None:
    row = await pool.fetchrow(
        "SELECT payload FROM events WHERE agent_id = $1 AND kind = $2 "
        "ORDER BY captured_at DESC LIMIT 1",
        agent_id, kind,
    )
    return row["payload"] if row else None


async def get_smtp_settings(pool) -> dict:
    """Resolve effective SMTP settings: DB settings table first, env as fallback.

    Keys persisted during first-run setup: smtp_host, smtp_port, smtp_user,
    smtp_password, smtp_from, smtp_to, smtp_encryption.
    """
    from . import config, vault

    db = await pool.fetch("SELECT key, value FROM settings WHERE key LIKE 'smtp_%'")
    kv = {r["key"]: r["value"] for r in db}

    host = kv.get("smtp_host") or config.SMTP_HOST
    port = int(kv.get("smtp_port") or config.SMTP_PORT)
    user = kv.get("smtp_user") or config.SMTP_USER
    password = vault.decrypt(kv.get("smtp_password") or "") or config.SMTP_PASSWORD
    from_addr = kv.get("smtp_from") or config.SMTP_FROM or user
    to = [
        s.strip()
        for s in (kv.get("smtp_to") or ",".join(config.SMTP_TO)).split(",")
        if s.strip()
    ]
    encryption = kv.get("smtp_encryption") or config.SMTP_ENCRYPTION
    return {
        "host": host,
        "port": port,
        "user": user,
        "password": password,
        "from": from_addr,
        "to": to,
        "encryption": encryption,
    }


async def _check(pool, agent: dict, kind: str, condition: dict):
    """Return (triggered, message)."""
    if kind == "offline":
        if not agent["last_seen"]:
            return False, ""
        minutes = condition.get("minutes", 15)
        stale = datetime.now(timezone.utc) - agent["last_seen"] > timedelta(minutes=minutes)
        return stale, f"{agent['hostname']} offline — no report for {minutes}+ min"
    if kind == "disk-low":
        p = await _latest_payload(pool, agent["id"], "diskhealth")
        if not p:
            return False, ""
        low = [d for d in (p.get("logical") or []) if d.get("FreePercent") is not None
               and d["FreePercent"] < condition.get("percent", 10)]
        if low:
            detail = ", ".join(f"{d['Drive']} {d['FreePercent']}% free" for d in low)
            return True, f"{agent['hostname']} low disk space: {detail}"
        return False, ""
    if kind == "smart-predict":
        p = await _latest_payload(pool, agent["id"], "diskhealth")
        if not p:
            return False, ""
        fails = p.get("smart_failures") or []
        if p.get("predicted_failure") and fails:
            return True, f"{agent['hostname']} SMART predicts disk failure ({len(fails)} disk(s))"
        return False, ""
    if kind == "battery-low":
        p = await _latest_payload(pool, agent["id"], "hardware")
        if not p or not p.get("battery"):
            return False, ""
        charge = p["battery"].get("charge_percent")
        if charge is None:
            return False, ""
        if charge < condition.get("percent", 20):
            return True, f"{agent['hostname']} battery at {charge}%"
        return False, ""
    if kind == "service-down":
        p = await _latest_payload(pool, agent["id"], "health")
        if not p:
            return False, ""
        stopped = p.get("critical_services_stopped") or []
        if stopped:
            names = ", ".join(s.get("Name", "?") for s in stopped[:5])
            return True, f"{agent['hostname']} stopped services: {names}"
        return False, ""
    if kind == "reboot-pending":
        p = await _latest_payload(pool, agent["id"], "health")
        if not p:
            return False, ""
        if not p.get("reboot_pending"):
            return False, ""
        days = condition.get("uptime_days", 7)
        uptime = p.get("uptime_hours") or 0
        if uptime >= days * 24:
            return True, f"{agent['hostname']} reboot pending (up {round(uptime/24,1)} days)"
        return False, ""
    return False, ""


async def _send_alert_email(pool, opened_alerts: list[dict]) -> bool:
    """Send one digest email for the alerts opened this eval run.

    Settings come from the DB (set during first-run setup) with env fallback.
    No-op when SMTP is not configured. Runs in a thread so the eval loop is
    not blocked. Returns True if a message was accepted for delivery.
    """
    smtp = await get_smtp_settings(pool)
    if not smtp["host"] or not smtp["to"]:
        return False

    portal = (await pool.fetchval("SELECT value FROM settings WHERE key = 'server_host'")) or "localhost"

    def _send() -> bool:
        msg = EmailMessage()
        msg["Subject"] = f"[IT-Toolkit] {len(opened_alerts)} new alert(s)"
        msg["From"] = smtp["from"] or smtp["user"]
        msg["To"] = ", ".join(smtp["to"])
        lines = [
            "The following alert(s) were opened:",
            "",
            *[f"- [{a['severity']}] {a['hostname']}: {a['message']}" for a in opened_alerts],
            "",
            f"Open the portal to ack/resolve: https://{portal}/",
        ]
        msg.set_content("\n".join(lines))
        try:
            if smtp["encryption"] == "ssl":
                with smtplib.SMTP_SSL(smtp["host"], smtp["port"], timeout=20) as srv:
                    if smtp["user"]:
                        srv.login(smtp["user"], smtp["password"])
                    srv.send_message(msg)
            else:
                with smtplib.SMTP(smtp["host"], smtp["port"], timeout=20) as srv:
                    if smtp["encryption"] == "starttls":
                        srv.starttls()
                    if smtp["user"]:
                        srv.login(smtp["user"], smtp["password"])
                    srv.send_message(msg)
            return True
        except Exception as exc:
            logger.error("alert email send failed: %r", exc)
            return False

    return await asyncio.to_thread(_send)


async def get_webhook_settings(pool) -> dict:
    """Resolve effective webhook alert settings (DB first, env fallback).

    Keys persisted via the portal Alerts view: webhook_enabled, webhook_url,
    webhook_type (generic | slack | teams). webhook_token is optional (Bearer).
    """
    from . import config

    db = await pool.fetch("SELECT key, value FROM settings WHERE key LIKE 'webhook_%'")
    kv = {r["key"]: r["value"] for r in db}
    return {
        "enabled": (kv.get("webhook_enabled") or config.WEBHOOK_ENABLED).lower() == "true",
        "url": kv.get("webhook_url") or config.WEBHOOK_URL,
        "type": kv.get("webhook_type") or config.WEBHOOK_TYPE,
        "token": kv.get("webhook_token") or "",
    }


def _webhook_payload(alerts: list[dict], webhook_type: str, portal: str) -> tuple[str, dict]:
    """Return (media_type, payload_dict) shaped for the target channel."""
    lines = [f"- [{a['severity']}] {a['hostname']}: {a['message']}" for a in alerts]
    body = "\n".join(lines) or "(empty)"
    if webhook_type == "slack":
        return (
            "application/json",
            {
                "text": f"IT-Toolkit: {len(alerts)} new alert(s)",
                "blocks": [
                    {"type": "section", "text": {"type": "mrkdwn", "text": f"*{len(alerts)} new alert(s)*"}},
                    {"type": "section", "text": {"type": "mrkdwn", "text": body}},
                    {"type": "context", "elements": [{"type": "mrkdwn", "text": f"Portal: <https://{portal}/|open>"}]},
                ],
            },
        )
    if webhook_type == "teams":
        return (
            "application/json",
            {
                "@type": "MessageCard",
                "@context": "http://schema.org/extensions",
                "summary": f"IT-Toolkit: {len(alerts)} new alert(s)",
                "themeColor": "0072C6",
                "title": f"{len(alerts)} new alert(s)",
                "text": body,
            },
        )
    return (
        "application/json",
        {"source": "it-toolkit", "event": "alerts.opened", "count": len(alerts), "alerts": alerts, "portal": portal},
    )


async def _send_alert_webhook(pool, opened_alerts: list[dict]) -> bool:
    """POST one digest to a configured webhook (Slack / Teams / generic).

    No-op unless enabled + a URL is configured. Runs in a thread so the eval
    loop is not blocked. Returns True if a 2xx response was received.
    """
    cfg = await get_webhook_settings(pool)
    if not cfg["enabled"] or not cfg["url"]:
        return False

    portal = (await pool.fetchval("SELECT value FROM settings WHERE key = 'server_host'")) or "localhost"
    media_type, payload = _webhook_payload(opened_alerts, cfg["type"], portal)
    data = json.dumps(payload).encode("utf-8")

    def _post() -> bool:
        req = urllib.request.Request(cfg["url"], data=data, method="POST")
        req.add_header("Content-Type", media_type)
        if cfg["token"]:
            req.add_header("Authorization", f"Bearer {cfg['token']}")
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                ok = 200 <= resp.status < 300
                if not ok:
                    logger.error("alert webhook rejected: HTTP %s", resp.status)
                return ok
        except Exception as exc:
            logger.error("alert webhook send failed: %r", exc)
            return False

    return await asyncio.to_thread(_post)


async def evaluate_rules(pool) -> int:
    """Evaluate all enabled rules; return number of alerts opened this run."""
    from . import metrics

    opened = 0
    opened_alerts: list[dict] = []
    rules = await pool.fetch("SELECT * FROM alert_rules WHERE enabled = TRUE")
    agents = await pool.fetch("SELECT id, hostname, last_seen FROM agents")
    for rule in rules:
        for agent in agents:
            triggered, message = await _check(pool, agent, rule["condition"].get("kind"), rule["condition"])
            if triggered:
                existing = await pool.fetchrow(
                    "SELECT id FROM alerts WHERE rule_id = $1 AND agent_id = $2 AND status = 'open'",
                    rule["id"], agent["id"],
                )
                if existing is None:
                    row = await pool.fetchrow(
                        "INSERT INTO alerts (rule_id, agent_id, severity, message) "
                        "VALUES ($1, $2, $3, $4) RETURNING severity, message",
                        rule["id"], agent["id"], rule["severity"], message,
                    )
                    opened += 1
                    metrics.alerts_opened.inc()
                    opened_alerts.append(
                        {"hostname": agent["hostname"], "severity": row["severity"], "message": row["message"]},
                    )
            else:
                await pool.execute(
                    "UPDATE alerts SET status = 'resolved', resolved_at = now() "
                    "WHERE rule_id = $1 AND agent_id = $2 AND status IN ('open', 'acknowledged')",
                    rule["id"], agent["id"],
                )
    if opened_alerts:
        await asyncio.gather(
            _send_alert_email(pool, opened_alerts),
            _send_alert_webhook(pool, opened_alerts),
        )
    return opened


async def alert_loop() -> None:
    from . import config, db

    interval = max(config.ALERT_EVAL_MINUTES, 1) * 60
    while True:
        try:
            pool = await db.connect()
            await seed_rules(pool)
            opened = await evaluate_rules(pool)
            if opened:
                logger.info("alert eval: %s new alert(s)", opened)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.error("alert eval failed: %r", exc)
        await asyncio.sleep(interval)
