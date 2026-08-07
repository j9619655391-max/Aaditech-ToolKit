# IT-Toolkit Enterprise — Product Roadmap & Implementation Plan

> **Purpose:** Single design doc for everything after the Phase 3 scaffold.
> Rev 2 — incorporates the agreed order: **setup first (company / IP / admin /
> branding + certificates) → then the agent is built from that info**. Plus
> team user management with roles (admin / operation / monitoring) and the full
> support-engineer feature set.
>
> Keeps the **zero-change promise**: existing toolkit files are never modified —
> everything additive lives under `Enterprise/`.

---

## 0. North star (revised flow)

```
1. Fresh server → ./deploy.sh → open http://<server>/
2. First visit → SETUP WIZARD:
     Company name · Server IP · Admin username + password · Branding
3. Server auto-generates on THIS system:
     CA certificate + server certificate (local, persisted)
     Authentication token
     Company-scoped agent config (endpoint + token + CA trust)
4. NOW the agent package is built from that info:
     one-click download → installs → fleet appears
5. Admin adds team users (operation / monitoring) → RBAC in portal
6. Collectors → health/inventory panels; commands; alerts; reports
```

Nothing is baked before setup completes — the agent, token, and certificates
are all derived from the setup answers.

---

## 1. Current state (done & verified)

- Server: FastAPI + PostgreSQL + Caddy in Docker (one host, one DB) — verified live.
- Agent: PowerShell wrapper (sanitize → local queue → HTTPS ingest) — verified end-to-end.
- Deploy: `deploy.sh` LAN-first, `--regen`/`--public`, auto-generated secrets.
- Portal: single-page UI (Agents / Events / Feature toggles / Users / Agent Setup) — **session login, RBAC roles, no shared token input**.
- **P1 done & verified live** (see §3): first-time setup wizard, local CA + server
  certs, first admin account, login/logout/me/bootstrap, CA download, agent template.
- **P2 done & verified live** (see §4): team users + RBAC (admin / operation /
  monitoring), Users page, role-gated routes + UI.
- **P3 done & verified live** (see §5): company agent bundle (agent.json +
  ca.crt + install-agent.cmd) + download endpoints; MSI serving from the
  `agent_artifacts` volume (waits on P0 CI build for a real binary).
- **P4 done & verified live** (see §6): 7 support-engineer collectors +
  structured-JSON agent output + fleet panels (offline/disk/battery/updates/health).
- **P5 done & verified live** (see §7): command channel — issue/poll/execute/
  result for reboot, wake, run-script (allowlisted + flag-gated); RBAC enforced.
- **P6 done & verified live** (see §8): alerts (seeded rules + background eval
  loop + auto-resolve + ack/resolve) and reports (fleet CSV + per-agent
  JSON/CSV); Alerts + Reports portal pages, open-alert badge.
- **P0 done & verified (2026-08-07)**: `agent-build` CI job runs green
  end-to-end — exe (ps2exe) + MSI (WiX v5) artifacts; MSI deployed to the
  `agent_artifacts` volume so `/api/agent-msi` serves a real installer.
- **SMTP alert email done & verified (2026-08-07)**: optional digest email
  when the eval loop opens new alerts (`SMTP_HOST`/`SMTP_TO` in `.env`), plus a
  `POST /api/alerts/test-email` admin check — verified end-to-end with a local
  MailHog sink.
- CI: PowerShell validation + agent build both green on `windows-latest`.

---

## 2. P0 — CI builds the generic agent engine (parallel prep) ✅ DONE (2026-08-07)

> **Implemented & verified end-to-end:** the `agent-build` job on
> `windows-latest` now stages `agent-config.json` from the repo secrets
> `SERVER_ENDPOINT` + `API_TOKEN` (set via API), installs ps2exe + WiX v5, and
> produces `IT-Toolkit-Agent.exe` + `IT-Toolkit-Agent.msi` (WiX pinned to v5 —
> v7 requires the OSMF EULA). Artifacts are uploaded and the MSI is copied into
> the server's `agent_artifacts` volume; `GET /api/agent-msi` returns a valid
> installer. Both CI jobs are green.

**Why generic:** a Windows `.exe`/`.msi` can only be compiled on Windows (CI).
The server (Linux) cannot produce the binary — but it CAN produce the
**per-company package** that wraps it. So:

- `agent-build` job (windows-latest) builds a **generic** exe + msi:
  no endpoint, no token, no company — just the agent engine.
- CI publishes the generic artifacts (release/artifact), uploaded to the server
  volume `agent_artifacts` (or downloaded by `deploy.sh`/admin).
- **Verify:** artifact contains exe + msi + template config; all CI checks green.

The *company-specific* agent (step 4 of the north star) is assembled **after
setup** by the server (P3), never inside CI.

---

## 3. P1 — First-time setup wizard + local certificates ✅ DONE (2026-08-07)

> **Implemented & verified live** on the current machine (`10.73.77.26`):
> `POST /api/setup` guarded to one-shot (409 after), `settings` + `users` tables
> (schema.sql + idempotent runtime migration), `certs.py` (local CA + server cert
> persisted under `api_data:/data/certs`, `ca.key` never leaves the volume),
> `auth.py` (PBKDF2-SHA256 hashing, HMAC-signed session cookies, `SESSION_SECRET`
> persisted), session-based admin API, `GET /api/ca.crt` download, `GET
> /api/agent-template`, and a setup wizard + login + branded header in the portal.
> E2E: setup → login → me → bootstrap → agent-template → CA → agents/events →
> `/ingest` (bearer) all pass; re-setup returns 409.

### 3.1 Setup form (`/api/setup/status` → `/` shows wizard when `settings.setup_complete != true`)
| Field | Required | Notes |
| --- | --- | --- |
| Company name | ✅ | Used in branding + agent config |
| Server IP / host | ✅ | Pre-filled from detection; admin confirms/overrides |
| Admin username + password | ✅ | First admin account |
| Branding | ⬜ | Header text/title; optional theme color; optional logo file |

### 3.2 On submit — everything generated on this system
1. **Local CA + server cert** (Python `cryptography` / `openssl`, persisted in
   the `api_data` volume under `certs/`):
   - `ca.crt` + `ca.key` — self-signed root CA (this machine).
   - `server.crt` signed by the CA for `<SERVER_HOST>` (IP or domain).
   - Caddy/API switches to it → **HTTPS works on a bare IP**, and because the
     agent package ships `ca.crt`, agents trust the server automatically
     (kills the old "self-signed warning" wart).
2. **Authentication token** — generated (existing `secrets.token_urlsafe`) and
   stored; kept as the agent/API bearer credential.
3. **Company-scoped agent template** — endpoint = `https://<SERVER_HOST>/ingest`,
   token, `company_name`, feature manifest, CA trust.
4. **`settings` + first `admin` user persisted**; `setup_complete=true`.

### 3.3 Guardrails
- `/setup` reachable only until configured; after that admin-login-only to re-run.
- Re-run does not destroy agents/events data.
- Certs + keys never leave the volume; `ca.key` is server-only.

---

## 4. P2 — Team users & RBAC (admin creates the team) ✅ DONE (2026-08-07)

> **Implemented & verified live:** `require_role()` dependency enforcing
> admin / operation / monitoring on every admin route; `/api/users` CRUD
> (admin-only) — create, change role, disable/enable, reset password (self-
> disable blocked); feature toggling gated to admin/operation; `monitoring` is
> read-only (403 on PUT); non-admins never receive `agent_token`; disabled
> users are rejected at login; portal shows a **Users** tab only for admins and
> hides config controls for monitoring.

### 4.1 Model
- `users` (id, username, password_hash, role, active, created_by, created_at).
- Roles:
  | Role | Capabilities |
  | --- | --- |
  | **admin** | Everything: setup, user mgmt, config, commands, alerts, reports, downloads |
  | **operation** (operator) | View all + issue commands + ack alerts + download agent; no user mgmt |
  | **monitoring** | Read-only dashboards + alerts; no commands, no user mgmt, no config |

### 4.2 Portal
- Login page (username/password) → signed session cookie. ✅
- **Users page** (admin-only): create/disable users, assign role, reset password. ✅
- Every API route checks role; portal UI hides what the role can't do. ✅

---

## 5. P3 — Agent package generation + download (post-setup) ✅ DONE (2026-08-07)

> **Implemented & verified live:** server-side company bundle — `GET
> /api/agent-bundle` assembles `agent.json` (endpoint = scheme+host, token,
> company, live feature overrides), `ca.crt`, and a generated
> `install-agent.cmd` (installs MSI then drops company `agent.json` + `ca.crt`
> over the bundled template + sets registry overrides). Downloads:
> `/api/agent/agent.json`, `/api/agent/install.cmd`, `/api/ca.crt`,
> `/api/agent-msi` (**live since P0** — the CI-built MSI is in the
> `agent_artifacts` volume). All gated to admin/operation (monitoring →
> 403). Portal **Agent Setup** tab shows download buttons + live previews.

Runs only after P1 so the package contains the setup answers:

1. Server assembles the **company agent bundle**:
   - `agent.json` — endpoint, token, company name, feature manifest ✅
   - `ca.crt` — server trust (agents accept the server cert) ✅
   - optional per-agent client cert for **mTLS** (flag; default bearer token) ⬜
2. **Download page** (branded):
   - `IT-Toolkit-Agent.msi` (generic engine from P0) + `agent.json` + `ca.crt` ✅
   - `install-agent.cmd` — generated live ✅
   - One click → installs → registers → fleet row appears. ✅ (once MSI uploaded)
3. Intune/GPO/SCCM: push the generic MSI + the exported `agent.json`/`ca.crt`
   (registry override still available). ✅

---

## 6. P4 — Support-engineer collectors (all requested, kept) ✅ DONE (2026-08-07)

> **Implemented & verified live:** 7 collectors in `Enterprise/agent/collectors/`
> (hardware incl. battery wear %, software, diskhealth/SMART, system health,
> bitlocker, update compliance, licenses — partial keys only, default off).
> Each emits one JSON object; `Agent-Collect.ps1` now auto-parses structured
> output (falling back to text) so the server stores real `jsonb` dicts for
> fleet panels. Manifest (`features.json`) drives both the portal toggles and
> the company agent bundle; deploy.sh derives its feature list from the same
> file. MSI bundles collectors at `<root>\Enterprise\agent\collectors\`.
> Portal **Fleet** view: offline, disk health/SMART, battery wear, update
> compliance, system health — licenses admin-only.

New collectors live in **`Enterprise/agent/collectors/`** (bundled by the MSI
build; the existing `Scripts/` tree stays byte-identical). The existing agent
wrapper already runs + sanitizes + ships them — zero core change.

| Collector | Kind | Payload highlights |
| --- | --- | --- |
| `Get-HardwareInventory.ps1` | `hardware` | CPU/RAM/disks/GPU/BIOS/serial, **battery wear %** |
| `Get-SoftwareInventory.ps1` | `software` | installed apps + versions |
| `Get-DiskHealth.ps1` | `diskhealth` | SMART status + predicted failure |
| `Get-SystemHealth.ps1` | `health` | temps, uptime, reboot-pending, critical services |
| `Get-BitLockerStatus.ps1` | `bitlocker` | volume encryption state |
| `Get-WindowsUpdateStatus.ps1` | `updatecompliance` | pending patches, last install date |
| `Get-LicenseInfo.ps1` | `licenses` | product keys (sensitive — sanitized, admin-only) |

Portal: `/api/events` already stores arbitrary `kind` + JSONB → no API change;
new kind-specific fleet panels (disk health, battery, update compliance, offline). ✅

---

## 7. P5 — Command channel (remote ops) ✅ DONE (2026-08-07)

> **Implemented & verified live:** `commands` table (schema.sql + runtime
> migration). Issue: `POST /api/commands` (admin/operation; `monitoring` 403;
> unauthenticated 401). Agent polls `GET /api/commands/poll?hostname=...`
> (bearer token) → marks `picked_up` (re-delivered within a 5-min window in
> case results are lost) → executes → posts `POST /api/commands/{id}/result`.
> Kinds: `reboot` (optional delay), `wake` (WOL magic packet), `run-script`
> (flag `COMMANDS_RUN_SCRIPT_ALLOWED` + `RUN_SCRIPT_ALLOWLIST`, 403 otherwise).
> Portal **Commands** page: issue form (per-kind fields) + history with
> payload/result viewer; issue hidden for monitoring.

- Table `commands` (id, agent_id, kind, payload, status, created_at, completed_at).
  Kinds: `reboot`, `wake` (L2), `run-script` (allowlisted, flag-gated). ✅
- Agent polls `GET /api/commands/poll?agent=<id>` every cycle → executes → posts
  result (reuses `/ingest` or `POST /api/commands/{id}/result`). ✅
- Portal: Commands page — pick agent, issue, watch status/result. Audited. ✅
- **RBAC:** `admin`/`operation` only; `monitoring` read-only. ✅

---

## 8. P6 — Alerts + reporting ✅ DONE (2026-08-07)

> **Implemented & verified live:** `alert_rules` + `alerts` tables (schema.sql
> + runtime migration, `idx_alerts_status`). Rules seeded idempotently on
> startup/eval (`rules.py::seed_rules`): agent-offline (15 min), disk-low (<10%
> free on a logical volume), smart-predict (SMART predicted failure), battery-low
> (<20%), service-down (critical service stopped), reboot-pending (>7 days
> uptime). Background `alert_loop()` (asyncio, `ALERT_EVAL_MINUTES` env, default
> 1 min) opens an alert once per rule/agent while a condition fires and **auto-
> resolves** open/acknowledged alerts when it clears; a persistent condition
> re-opens after manual resolve. Portal Alerts page (status filter + ack/resolve,
> rule admin panel with live toggle/severity/condition edit) + open-alert badge
> polling `/api/alerts/open` every 30s. Reports: `GET /api/report/fleet` (CSV),
> `GET /api/report/agent/{id}?format=json|csv`; Reports page with export links.
> E2E: 3 rules fired from ingested fixtures, ack/resolve + RBAC (monitoring 403,
> operation/admin 200), auto-resolve on condition clear, re-open on persistent
> condition, all report exports — verified; test data reset to first-run.

- `alert_rules` (name, description, condition json, severity, enabled) + `alerts`
  (rule_id, agent_id, severity, message, status, created_at, resolved_at). ✅
- Seeded rules: **agent offline** (last_seen > X), disk < Y%, SMART
  predicted-failure, service down, battery < 20%, reboot-pending > 7 days. ✅
- Eval loop in the API (background task); portal Alerts page + badge
  (email via SMTP = optional flag). ✅ **SMTP email also implemented & verified** (P6.1)
- Reports: `GET /api/report/fleet` (CSV) + `GET /api/report/agent/{id}`
  (JSON/CSV); Reports page with export buttons. ✅

---

## 9. Phases (dependency-ordered)

| Phase | Scope | Depends on | Est. |
| --- | --- | --- | --- |
| **P0** | CI generic exe/msi build + verify artifacts ✅ | — | small |
| **P1** | Setup wizard + CA/server certs + token + first admin ✅ | — | medium |
| **P2** | Users + RBAC (admin/operation/monitoring) + portal login ✅ | P1 | medium |
| **P3** | Agent bundle (config+CA) + download page + install-agent.cmd ✅ | P0, P1 | small |
| **P4** | Collectors + fleet panels ✅ | P3 | medium |
| **P5** | Command channel (poll/execute/UI) ✅ | P2 | large |
| **P6** | Alerts + reporting ✅ | P4 | medium |

Each phase lands green on CI and keeps the existing toolkit untouched.

---

## 10. Security & migration notes
- **Certificates first:** local CA signs server cert (trusted TLS on IP) and
  optional per-agent client certs (mTLS) — auth is certificate-backed, not
  just a shared secret. `ca.key` stays server-only.
- **RBAC:** admin / operation / monitoring enforced in API + portal.
- Passwords hashed (PBKDF2-SHA256 with per-user salt + 120k iterations; swap-in
  for argon2 later); sessions are HMAC-signed cookies with a persisted
  `SESSION_SECRET`; commands audited; `run-script` allowlisted by default;
  `licenses` kind admin-only + sanitized.
- Multi-tenant later: `companies` field on users/agents is schema-ready from P1.
- Moving servers stays `deploy.sh --regen`; state is only in the data volumes.

---

## 11. Open decisions (confirm before each phase)
1. **mTLS now or bearer-token first?** ✅ **Decided:** bearer token first (live).
   **Remaining (optional flag):** per-agent client certs for mTLS — the local CA
   infra from P1 is ready; flipping it on is additive, default stays bearer.
2. **Alerts channel:** ✅ **Decided & implemented:** portal-first (P6) **+ optional
   SMTP email** (P6.1, verified) — set `SMTP_HOST` + `SMTP_TO` in `.env`; digest
   email on new alerts; `POST /api/alerts/test-email` for admin checks.
3. **Remote command scope:** ✅ **Decided:** reboot + Wake-on-LAN + `run-script`
   allowlist behind a flag — implemented in P5.
4. **Exe signing:** ⬜ **Open — needs a purchased code-signing certificate.**
   Today: manual Authenticode after CI build; with a cert you can sign inside the
   `agent-build` job (add it to the repo secrets + one `Set-AuthenticodeSignature`
   step). Nothing blocks the pipeline without it.
5. **License info:** ✅ **Decided:** include but off by default — implemented in P4
   (last-5 keys only, admin-only portal panel).
6. **Roles to ship:** ✅ **Decided:** admin / operation / monitoring — implemented in P2.

### Remaining after P0–P6.1 (all optional / non-blocking)
- **mTLS client certs** (flag on the existing CA).
- **Code-signing cert** for the exe/MSI (requires purchase).
- **Windows smoke run** — full agent install + collector/command round-trip on a
  real client (CI can't run the interactive pieces; see VERSION.md smoke-run list).

---

## 12. Success criteria
Fresh `deploy.sh --regen` → `/` shows setup wizard → enter company name, IP,
admin creds, branding → certs + token generated locally → branded portal →
admin creates an "operation" teammate → one-click download installs on a real
Windows box → fleet row appears → hardware/health panels populate → a simulated
disk-low triggers an alert → a remote reboot is issued and result visible →
monitoring-role user sees dashboards but cannot send commands. All without
editing a single existing toolkit file.
