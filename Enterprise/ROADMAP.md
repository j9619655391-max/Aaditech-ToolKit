# IT-Toolkit Enterprise — Product Roadmap & Implementation Plan

> **Purpose:** Single design doc for everything after the Phase 3 scaffold.
> Covers: (A) real agent delivery from CI, (B) first-time setup wizard, and
> (C) the support-engineer feature set. Each item is phased, dependency-ordered,
> and keeps the **zero-change promise** (existing toolkit files are never
> modified — everything additive lives under `Enterprise/`).

---

## 0. North star

A support engineer opens `http://<server>/` on a fresh intranet server and is
walked through: **Company name → everything self-configures → download the
agent → fleet appears → inventory/health/alerts/remote-ops all usable.**

No manual secret setup, no hand-editing config, no recompile per customer.

---

## 1. Current state (done & verified)

- Server: FastAPI + PostgreSQL + Caddy in Docker (one host, one DB) — verified live.
- Agent: PowerShell wrapper (sanitize → local queue → HTTPS ingest) — verified end-to-end.
- Deploy: `deploy.sh` LAN-first, `--regen`/`--public`, auto-generated secrets.
- Portal: single-page UI (Agents / Events / Feature toggles) — one shared token.
- CI: `agent-build` job scaffolded (**not yet run end-to-end**).

---

## 2. Workstream A — Agent delivery pipeline (CI-built, server-hosted)

**Problem today:** `agent-build` CI job is untested; the MSI bakes the endpoint
at build time, which is wrong for a product (rebuild per IP/company).

**Design decision:** the **exe/MSI are generic** (built once per OS by CI); the
**per-deployment config is generated server-side** and shipped alongside.

### A1. Make the CI build real
- Add repo secrets `SERVER_ENDPOINT` (optional) + `API_TOKEN` (optional).
- Fix `agent-build` job so it **never requires an endpoint at build time**:
  - `build-agent.ps1` produces the exe from a **generic** `agent-config.template.json`
    (endpoint placeholder, empty token).
  - `build-msi.ps1` bundles the exe + template config only.
- Run the workflow via `workflow_dispatch` → download `it-toolkit-agent` artifact.
- **Verify:** the artifact contains exe + msi + template config; parse/JSON CI still green.

### A2. Server hosts the download (connect to Workstream B)
- New volume `agent_artifacts:/data/artifacts` — CI uploads artifacts there
  (via `gh release` or a repo-releases download step), or an admin drops files in.
- New endpoint `GET /download/agent` → returns the current MSI/exe.
- New endpoint `GET /download/bootstrap` → returns a tiny `install-agent.cmd`
  generated **live** by the server:
  1. fetches `GET /agent-config` (company token, endpoint = request host) and
     writes it to `C:\ProgramData\ITToolkit-Agent\agent.json`,
  2. runs `msiexec /i IT-Toolkit-Agent.msi /qn`.
- Result: one download, double-click, done — **no endpoint/IP in any repo or binary**.

### A3. Intune/GPO/SCCM path (unchanged philosophy)
- MSI stays generic; admins push `agent.json` (from `/agent-config`) or use the
  existing `HKLM\SOFTWARE\ITToolkit\Agent` registry override.

---

## 3. Workstream B — First-time setup wizard (company bootstrap)

**Goal:** first visit → setup → branded portal + ready-to-download agent.

### B1. Data model (new tables)
- `settings` (key TEXT PK, value TEXT) — `company_name`, `setup_complete`, `admin_email`.
- `admins` (id, username, password_hash, created_at) — bcrypt/argon2 via
  `passlib`; replaces the shared-token-only model.
- `companies` (id, name, created_at) — **add now, use later** so multi-tenant
  migration is a schema field, not a rewrite.

### B2. Flow
1. On startup, if `settings.setup_complete` != true → **every** portal/API
   request redirects to `/setup` (except `/healthz` and `/setup` itself).
2. `/setup` page: **Company name** (required) + admin username/password.
3. On submit (POST `/api/setup`):
   - store settings + admin account (hashed),
   - generate the company `agent.json`: `endpoint = http(s)://<SERVER_HOST>/ingest`,
     token = the deployment `API_TOKEN` (or a company-scoped one),
   - set `setup_complete=true`.
4. `/` portal now branded: header shows `<Company> — IT Toolkit`; login page
   (admin session cookie, not just the shared token).

### B3. Portal additions
- Login/session middleware (admin cookie + optional bearer for agents).
- "Download Agent" page: big buttons for `.msi` and `install-agent.cmd` (both
  auto-generated), plus a note for Intune/GPO admins.

### B4. Guardrails
- Re-run of `/setup` requires an admin login; does not destroy existing data.
- Secrets still never committed; `.env` still the source of the base token.

---

## 4. Workstream C — Support-engineer feature set

Split into three sub-phases by dependency.

### C1. Fleet inventory & health (new collectors, zero core change)
New collector scripts live in **`Enterprise/agent/collectors/`** (bundled by the
MSI build; the existing `Scripts/` tree stays byte-identical). Each is a normal
PowerShell script the existing agent wrapper already runs + sanitizes + ships.

| Collector | Kind | Payload highlights |
| --- | --- | --- |
| `Get-HardwareInventory.ps1` | `hardware` | CPU/RAM/disks/GPU/BIOS/serial, **battery wear %** (laptop) |
| `Get-SoftwareInventory.ps1` | `software` | installed apps + versions |
| `Get-DiskHealth.ps1` | `diskhealth` | SMART status + predicted-failure |
| `Get-SystemHealth.ps1` | `health` | temps, uptime, reboot-pending, critical services |
| `Get-BitLockerStatus.ps1` | `bitlocker` | volume encryption state |
| `Get-WindowsUpdateStatus.ps1` | `updatecompliance` | pending patches, last install date |
| `Get-LicenseInfo.ps1` | `licenses` | product keys (sensitive — sanitized, admin-only) |

Server/portal:
- `/api/events` already stores arbitrary `kind` + JSONB payload → **no API change**;
  portal just gets new kind-specific panels (fleet matrix: disk health, battery,
  update compliance, offline agents).

### C2. Command channel (remote ops) — new server + agent capability
- Table `commands` (id, agent_id, kind, payload, status, created_at, completed_at).
  Kinds: `reboot`, `run-script` (allowlisted later), `wake` (L2 trigger).
- Agent, every cycle, `GET /api/commands/poll?agent=<id>` → executes → posts
  result back (reuses `/ingest` or `POST /api/commands/{id}/result`).
- Portal: Commands page — pick agent, issue reboot/command, see status/result.
- **Security:** admin-session-only; `run-script` behind an allowlist flag
  (default off); every command audited in `commands`.

### C3. Alerts + reporting
- Table `alert_rules` (name, condition json, severity, enabled) and `alerts`
  (rule_id, agent_id, severity, message, status, created_at).
- Built-in rules seeded at setup: **agent offline** (last_seen > X), disk < Y%,
  SMART predicted-failure, service down, battery < 20%, reboot-pending > 7 days.
- Alert evaluation: server-side periodic task (FastAPI background loop).
- Notification: portal Alerts page + badge (email via SMTP config = optional flag).
- Reporting: `GET /api/report/fleet` (CSV) + `GET /api/report/agent/{id}` (JSON/CSV);
  portal Reports page with export buttons.

---

## 5. Phased delivery order (dependency-ordered)

| Phase | Scope | Depends on | Est. |
| --- | --- | --- | --- |
| **P1** | A1 — CI build real + verify artifacts | — | small |
| **P2** | B1+B2 — settings/admins tables, `/setup` wizard, login, branding | — | medium |
| **P3** | A2+A3 — server download endpoints, install-agent.cmd, download page | P1, P2 | small |
| **P4** | C1 — collector scripts + portal fleet panels | — | medium |
| **P5** | C2 — command channel (poll + execute + UI) | P2 | large |
| **P6** | C3 — alert rules + offline detection + reports | P4 | medium |

Each phase lands green on CI and keeps the existing toolkit untouched.

---

## 6. Security & migration notes
- Admin passwords hashed (argon2/bcrypt); agent token = deployment/company scope.
- Command execution audited and (for arbitrary scripts) allowlisted by default.
- `licenses` kind is PII-adjacent → sanitized + admin-only in the portal.
- Multi-tenant: `companies` table added in P2 so later tenants are an insert,
  not a schema migration.
- Moving servers stays `deploy.sh --regen`; data volume is the only state.

---

## 7. Open decisions (confirm before/while building)
1. **Single-company now, multi-tenant later?** (Recommended: yes — schema ready in P2.)
2. **Alerts channel:** portal-only first, email via SMTP later? (Recommended: yes.)
3. **Remote command scope:** reboot + Wake-on-LAN first; arbitrary `run-script`
   allowlisted behind a flag? (Recommended: yes.)
4. **Agent exe signing:** Authenticode signing stays a manual Windows step, or
   add a code-signing cert to the CI job? (Requires buying a cert.)
5. **License info collection:** include in C1, or drop for compliance reasons?
   (Sensitive — recommend optional/off by default.)

---

## 8. Success criteria
- `./deploy.sh --regen` on a fresh machine → `/` shows setup wizard → enter
  company name → portal branded → one-click download → MSI installs on a real
  Windows box → fleet row appears within one cycle → hardware/health panels
  populate → an alert fires on a simulated disk-low → a remote reboot is issued
  and the result is visible. All without editing a single existing toolkit file.
