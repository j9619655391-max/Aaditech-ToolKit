# Local Full-Stack E2E Test -- IT-Toolkit Enterprise (macOS / Linux)

> **Purpose:** Run the complete Enterprise server flow on a developer machine
> (macOS or Ubuntu -- **identical steps**, only the IP/FQDN differs) **before**
> deploying to a real server. The real Windows agent (`.exe`/`.msi`) is
> Windows-only, so on macOS/Linux we substitute a **simulated agent** (plain
> `curl` against the agent-facing endpoints) to exercise the same server path:
> enroll -> heartbeat -> ingest -> portal visibility -> commands -> alerts.
>
> Every step below also applies verbatim to the Ubuntu VM used as the
> production host (Step 4 / `deploy.sh`); swap `localhost` for the VM's IP.

## Prerequisites

- Docker + compose v2 running.
- Repo cloned to a stable path (no spaces), e.g. `~/it-toolkit`.
- PowerShell 5.1 or pwsh available for the PS-parse sanity check (optional).
- Ports `80`, `443`, `9443` free (compose maps them).

## 1. Server bring-up (identical on macOS and Ubuntu)

```bash
cd Enterprise/deploy
./deploy.sh            # LAN mode; --public only if internet clients need it
```

`deploy.sh` auto-detects the machine's LAN IP (macOS + Linux both supported),
generates `.env` secrets, writes `agent/agent-config.json` (mTLS endpoint on
`:9443` + token), and runs `docker compose up -d --build` (db + api + caddy).

Verify the stack is healthy:

```bash
docker compose -f Enterprise/docker-compose.yml ps
# expect: enterprise-api-1 healthy, enterprise-db-1 healthy, enterprise-caddy-1 up
```

Health probe:

```bash
curl -s http://localhost/healthz        # -> {"status":"ok"}
```

## 2. First-run setup (web wizard)

Open `http://<host>/` and complete the wizard:

- Company name (this creates the F4 tenant + default company)
- Admin user + password
- Build mode: choose **GitHub Actions -- remote build** (Linux/macOS host cannot
  build the Windows MSI locally) and paste the repo -- **full URLs are fine**
  (`https://github.com/OWNER/REPO.git` is normalized to `OWNER/REPO`), plus a
  fine-grained PAT with `actions: read/write`.
- SMTP (optional)

Click **Finish**. The wizard ends with setup saved; the Agents tab is empty
until an agent connects -- that is expected.

## 3. Simulated agent (macOS/Linux stand-in for the Windows agent)

Grab the shared fleet token from `.env`:

```bash
TOKEN=$(grep -E '^API_TOKEN' Enterprise/.env | sed 's/^API_TOKEN=//')
```

### 3a. Heartbeat (creates the agent row)

```bash
curl -s -X POST http://localhost/api/agent/heartbeat \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"hostname":"TEST-MACBOOK-01","os":"macOS 14.6","agent_version":"1.0.0","ip":"192.168.1.25"}'
# -> {"ok":true,"last_seen":"..."}
```

### 3b. Ingest events (health + software + licenses)

```bash
curl -s -X POST http://localhost/ingest \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"hostname":"TEST-MACBOOK-01","os":"macOS 14.6","events":[
    {"kind":"health","payload":{"uptime_hours":4,"cpu_percent":12,"memory_percent":48,"reboot_pending":false},"captured_at":"2026-08-12T08:00:00Z","client_msg_id":"h-1"},
    {"kind":"software","payload":{"apps":[{"DisplayName":"Visual Studio Code","DisplayVersion":"1.93.0","Publisher":"Microsoft"}]},"captured_at":"2026-08-12T08:00:00Z","client_msg_id":"sw-1"},
    {"kind":"licenses","payload":{"windows_key_last5":"A1B2C","office_keys_last5":"D3E4F"},"captured_at":"2026-08-12T08:00:00Z","client_msg_id":"lic-1"}
  ]}'
# -> {"accepted":3,"agent_id":<id>}
```

> Only `health` is enabled by default in `features.json`. If `software` /
> `licenses` events 403, enable those features in the Features tab first
> (or set the matching `FEATURE_*` env var) and re-post.

### 3c. Command round-trip (optional but recommended)

1. In the portal **Commands** tab, pick `TEST-MACBOOK-01`, send e.g. a
   `quickcheck` command.
2. Simulate the agent picking it up + returning a result:

```bash
# find the command id: docker exec enterprise-db-1 psql -U ittoolkit -d ittoolkit \
#   -c "SELECT id, kind, status FROM commands ORDER BY id DESC LIMIT 3;"
curl -s -X POST "http://localhost/api/commands/<ID>/result" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"status":"succeeded","result":{"note":"hello from simulated agent"}}'
```

## 4. Portal verification checklist

Sign in with the admin account created in step 2.

- [ ] **Agents** -- `TEST-MACBOOK-01` listed with OS/IP/version/last-seen.
- [ ] **Fleet** -- health card shows CPU 12% / RAM 48% / uptime 4h.
- [ ] **Events** -- `health`, `software`, `licenses` events for the host.
- [ ] **Software** -- search `Code` finds Visual Studio Code; CSV export
      downloads; license compliance (admin) shows Windows key `A1B2C`.
- [ ] **Commands** -- the command shows delivered + result returned.
- [ ] **Alerts** -- webhook card saves the webhook URL/type/token; a triggered
      rule delivers to the webhook.
- [ ] **Agent Setup** -- GitHub remote-build panel shows the normalized repo
      (`OWNER/REPO`, no `https://.../...git` 404); build status reachable.
- [ ] **Users/Companies** -- company list shows the tenant created in setup;
      default company is set.

## 5. Automated test suite (optional)

Runs the same server contract (RBAC, setup, ingest, F3 software, F4 tenants,
webhooks) against a throwaway database -- the live data is never touched.

```bash
docker exec -e PYTHONPATH=/app -w /tmp/checkout-api enterprise-api-1 \
  python3 -m pytest tests -q
# expect: N passed
```

> `/tmp/checkout-api` inside the container must be refreshed after an image
> rebuild:
> `docker cp Enterprise/api/app enterprise-api-1:/tmp/checkout-api/app` etc.

## 6. Reusing this on the Ubuntu VM (production host)

The VM is provisioned with the same repo. Steps 1-5 are **byte-for-byte
identical**; only the host changes:

| macOS dev | Ubuntu VM (Hyper-V, LAN) |
|---|---|
| `./deploy.sh` (detects macOS) | `./deploy.sh` (detects Linux, `hostname -I`) |
| browse `http://localhost/` | browse `http://<vm-lan-ip>/` |
| MSI via GitHub remote build | MSI via GitHub remote build (same) |

The **only** difference: the real Windows agent (`IT-Toolkit-Agent.msi` from
`/api/agent-msi`) installs on actual Windows clients; a Linux VM cannot host
the Windows agent itself -- use the simulated-agent curls above to prove the
server, and the MSI on a real Windows machine for the client side.

## Notes / gotchas

- Agent rows only appear after a heartbeat/ingest -- setup itself creates no
  agents by design.
- Agents enrolled before multi-tenant F4 (NULL `company_id`) remain visible to
  company users (scope clause `company_id = X OR company_id IS NULL`).
- The GitHub repo is normalized on save and on every call -- pasting a full URL
  cannot produce the old `/repos/https://...` 404.
