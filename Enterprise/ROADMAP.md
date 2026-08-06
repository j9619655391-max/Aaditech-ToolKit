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
- CI: `agent-build` job scaffolded (generic binary path, **not yet run end-to-end**).

---

## 2. P0 — CI builds the generic agent engine (parallel prep)

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

## 5. P3 — Agent package generation + download (post-setup)

Runs only after P1 so the package contains the setup answers:

1. Server assembles the **company agent bundle**:
   - `agent.json` — endpoint, token, company name, feature manifest
   - `ca.crt` — server trust (agents accept the server cert)
   - optional per-agent client cert for **mTLS** (flag; default bearer token)
2. **Download page** (branded): 
   - `IT-Toolkit-Agent.msi` (generic engine from P0) + `agent.json` + `ca.crt`
   - `install-agent.cmd` — generated live: copies `agent.json` + `ca.crt` into
     `C:\ProgramData\ITToolkit-Agent\`, then `msiexec /i IT-Toolkit-Agent.msi /qn`
   - One click → installs → registers → fleet row appears.
3. Intune/GPO/SCCM: push the generic MSI + the exported `agent.json`/`ca.crt`
   (registry override still available).

---

## 6. P4 — Support-engineer collectors (all requested, kept)

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
new kind-specific fleet panels (disk health, battery, update compliance, offline).

---

## 7. P5 — Command channel (remote ops)

- Table `commands` (id, agent_id, kind, payload, status, created_at, completed_at).
  Kinds: `reboot`, `wake` (L2), `run-script` (allowlisted, flag-gated).
- Agent polls `GET /api/commands/poll?agent=<id>` every cycle → executes → posts
  result (reuses `/ingest` or `POST /api/commands/{id}/result`).
- Portal: Commands page — pick agent, issue, watch status/result. Audited.
- **RBAC:** `admin`/`operation` only; `monitoring` read-only.

---

## 8. P6 — Alerts + reporting

- `alert_rules` (name, condition json, severity, enabled) + `alerts`
  (rule_id, agent_id, severity, message, status, created_at).
- Seeded rules: **agent offline** (last_seen > X), disk < Y%, SMART
  predicted-failure, service down, battery < 20%, reboot-pending > 7 days.
- Eval loop in the API (background task); portal Alerts page + badge
  (email via SMTP = optional flag).
- Reports: `GET /api/report/fleet` (CSV) + `GET /api/report/agent/{id}`
  (JSON/CSV); Reports page with export buttons.

---

## 9. Phases (dependency-ordered)

| Phase | Scope | Depends on | Est. |
| --- | --- | --- | --- |
| **P0** | CI generic exe/msi build + verify artifacts | — | small |
| **P1** | Setup wizard + CA/server certs + token + first admin ✅ | — | medium |
| **P2** | Users + RBAC (admin/operation/monitoring) + portal login ✅ | P1 | medium |
| **P3** | Agent bundle (config+CA) + download page + install-agent.cmd | P0, P1 | small |
| **P4** | Collectors + fleet panels | P3 | medium |
| **P5** | Command channel (poll/execute/UI) | P2 | large |
| **P6** | Alerts + reporting | P4 | medium |

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
1. **mTLS now or bearer-token first?** (Recommended: bearer token first; mTLS
   client certs as a P3 flag — cert infra is already built in P1.)
2. **Alerts channel:** portal-first, SMTP email later? (Recommended: yes.)
3. **Remote command scope:** reboot + Wake-on-LAN first; `run-script` allowlist
   behind a flag? (Recommended: yes.)
4. **Exe signing:** manual Authenticode, or add a code-signing cert to CI?
   (Requires purchasing a cert.)
5. **License info:** include but off by default (optional per company)?
   (Recommended: yes, off by default.)
6. **Roles to ship:** exactly admin / operation / monitoring, or also a
   read-only "viewer"? (Recommended: the three above.)

---

## 12. Success criteria
Fresh `deploy.sh --regen` → `/` shows setup wizard → enter company name, IP,
admin creds, branding → certs + token generated locally → branded portal →
admin creates an "operation" teammate → one-click download installs on a real
Windows box → fleet row appears → hardware/health panels populate → a simulated
disk-low triggers an alert → a remote reboot is issued and result visible →
monitoring-role user sees dashboards but cannot send commands. All without
editing a single existing toolkit file.
