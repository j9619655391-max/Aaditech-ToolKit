# Changelog

## v1.3.1 — bugfixes (GitHub repo normalization + legacy-agent visibility)

- **GitHub repo normalization:** the repo is now canonicalized to `owner/repo`
  on save (setup + build trigger) and on every GitHub API call. Pasting a full
  URL (`https://github.com/OWNER/REPO.git`) previously produced a broken
  `/repos/https://github.com/…` request → `404: Not Found` in the Agent Setup
  tab; now full URLs, `git@github.com:` form, trailing `/`, and `.git` suffixes
  all collapse to the correct API path (`app/github.py` `_normalize_repo`).
- **Legacy-agent visibility (F4):** the company scope clause is now
  `company_id = $N OR company_id IS NULL`, so agents enrolled before
  multi-tenant (NULL `company_id`) no longer vanish from the Agents tab for
  company-scoped users — while cross-tenant isolation is preserved.
- **Tests:** suite grown to 27 — `_normalize_repo` edge cases and a live
  NULL-company agent visibility check.
- **Docs:** new `Documentation/PROJECT-SPEC.md` — a clean-room conceptual spec
  of the whole platform (3 layers, concepts + design-level contracts +
  acceptance checklist) for handing the project to a developer/AI agent.

## v1.3.0 — post-release feature additions (F1/F3/F4)

- **F1 — Webhook alert delivery:** new-alert digests can now be POSTed to a
  generic JSON endpoint, a Slack incoming webhook (blocks format), or a
  Microsoft Teams connector (MessageCard) in addition to SMTP email. Config +
  live test live on the portal Alerts page: `GET/PUT /api/alerts/webhook` and
  `POST /api/alerts/test-webhook` (admin-only). Delivered with stdlib
  `urllib.request` in a worker thread so the eval loop is never blocked.
- **F3 — Software inventory & license compliance:** new **Software** portal tab
  with fleet-wide search (app name/publisher, case-insensitive) and CSV export
  (`GET /api/software/search`, `GET /api/software/export`), plus an admin-only
  license compliance view/export showing Windows/Office key last-5 characters
  (`GET /api/license/compliance`, `GET /api/license/export`). Added an
  `idx_events_kind_agent` index for fast "latest event per agent" lookups.
- **F4 — Multi-tenant foundation:** setup now creates a `companies` tenant,
  binds the admin user (and every subsequently created user) to it, and new
  agents enroll into the current default company. Agent/event/alert/command/
  user/report queries are scoped to the signed-in user's company. Admin
  Companies manager in the Users tab (`GET/POST /api/companies`,
  `GET/POST /api/settings/default-company`); `bootstrap` returns the caller's
  tenant + (for admins) the company directory.
- **Tests:** API pytest suite grown to 25 cases covering webhook payload
  shapes + real local-server delivery, software search/export, license
  compliance RBAC, and cross-tenant isolation.

## v1.3.0 — Enterprise hardening + test tooling (SCALING-PLAN A–E)

- **Least-privilege agent task (E4):** routine scheduled task runs as
  `NETWORK SERVICE`; admin-only collectors (`users`, `printers`, `bitlocker`,
  `licenses`) are opt-in via `requires_elevation`; admin work (msiexec
  self-upgrade, scheduled reboot) is staged to an on-demand elevated task
  `ITToolkitAgentElevated` (runs as SYSTEM/Highest via `schtasks /run`,
  registered through the Task Scheduler COM API with a DACL that lets the
  unprivileged agent trigger it). `icacls` locks down ProgramData + the local
  `agent.json` to SYSTEM/Administrators/NETWORK SERVICE.
- **Agent maturity (E1–E3):** per-cycle heartbeat (`/api/agent/heartbeat`),
  bounded outbox pruning + exponential backoff with jitter, and staged
  self-update via a rollout target + silent MSI upgrade.
- **Observability & audit (D1–D3):** zero-dependency Prometheus `/metrics`,
  structured JSON logs with request-id correlation, and an admin-only fleet
  audit log (login / setup / user / command / agent / feature / build actions).
- **Reliability (C1–C6):** pg_dump/restore runbook, startup-only migrations,
  transactional ingest + bounded limits (413/limit clamp), transactional setup
  (retryable, `setup_complete` last), at-most-once commands + sanitized output,
  and automatic client-cert renewal before expiry.
- **Security (B1–B6):** admin-only `licenses`/audit RBAC, login rate-limit +
  per-user lockout, optional TLS main port, prod-gated API docs, Fernet
  secrets-at-rest for SMTP/GitHub PAT, and per-agent credentials (token + mTLS
  client cert) replacing the shared fleet token.
- **Foundation (A1–A7):** bundled sqlite3, single version source, working MSI
  upgrade path, real registry override, Caddy cert timing fix, honest deploy
  health checks, and 0600/icacls secret permissions.
- **Test tooling:** new `Enterprise/api/requirements-dev.txt` + pytest smoke
  suite (`Enterprise/api/tests/`) that runs against a throwaway Postgres DB and
  is wired into CI (`api-tests` job, Postgres service). New AI-agent
  prerequisite scanner (`Enterprise/tests/Check-Deploy-Prereqs.ps1`) +
  deployment runbook (`Documentation/Deployment-AI-Runbook.md`).
- **FIX:** `ci.yml` + `deploy.sh` now emit `requires_elevation` in the baked
  agent config (previously only `deploy.ps1` did), so the E4 gating works for
  CI-built MSIs and Linux/macOS deploys too.

## v3.9 UPDATES — SaaS auto-setup + GitHub remote build (Rev 3)

- **NEW: `Enterprise/deploy/deploy.ps1`** — one-command Windows Server bring-up:
  detects the LAN IP, auto-generates all `.env` secrets, writes the mTLS
  `agent-config.json` (`endpoint https://<host>:9443/ingest` + `enroll_url`),
  starts `db + api + caddy`, auto-generates a **code-signing CA**, builds the
  agent `.exe` (ps2exe) + `.msi` (WiX) **on the server**, signs them, and
  publishes the MSI into the `agent_artifacts` volume — `BUILD_MODE=local_windows`.
  Flags: `-Public`, `-Regen`, `-SkipBuild`.
- **NEW: GitHub remote-build mode** — `Enterprise/api/app/github.py` (stdlib-only
  GitHub client) + `GET /api/build/status`, `POST /api/build/validate`,
  `POST /api/build/trigger`. The setup wizard's **build-mode selector** stores
  `build_mode` / `github_repo` / `github_token` in `settings`; the Agent Setup
  page gained a **build panel** (trigger button + status + MSI availability).
  `/api/build/status` polls the latest `ci.yml` run (push **or**
  `workflow_dispatch`) and auto-downloads the newest successful MSI artifact.
  Verified live end-to-end: setup → validate → trigger → poll → download →
  `/api/agent-msi` serves a valid installer.
- **FIX: artifact download redirect** — GitHub's artifact API 302s to a signed
  CDN URL; the Bearer header must not be forwarded there (401). `download_msi`
  now captures the `Location` and re-issues the GET without auth headers.
- **FIX: `bool("0")` setup guards** — `setup_status`, `run_setup` (409 gate) and
  `require_setup_done` (428 gate) treated the string `"0"` as truthy; all three
  now parse `0`/empty/`false` correctly.
- **FIX: `github.validate` permissions** — the repo-info response has no
  `actions` key; `actions_write` now counts `admin`/`maintain` (was wrongly
  `False` for owners). `build_validate` also falls back to the stored PAT.
- **FIX: MSI auto-refresh** — the downloaded artifact is stamped
  (`.msi_artifact.json`); `_needs_msi_refresh` re-fetches when a newer
  successful artifact exists (previously only when no MSI was present).
- **deploy.sh + bundle.py** — now emit the mTLS `endpoint` (`:9443/ingest`) +
  `enroll_url` on the main port (fixes a latent `enroll_url` pointing at the
  TLS port Caddy doesn't serve on bare IPs).

## v3.8 UPDATES — SMTP alert email (P6.1)

- **NEW: optional alert email** — `rules.py` sends a digest email when the eval
  loop opens new alerts, configured via `.env`: `SMTP_HOST`, `SMTP_PORT` (587),
  `SMTP_USER`/`SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_TO` (comma-separated),
  `SMTP_STARTTLS` (default true). No-op when `SMTP_HOST` is unset (portal-first
  default). Send runs in a thread so the eval loop is never blocked.
- **NEW: `POST /api/alerts/test-email`** (admin) — sends a test message using the
  current SMTP config; 400 when SMTP is unconfigured, 502 if the send fails.
- **docker-compose.yml + `.env.example`** — SMTP vars wired through.
- **Verified end-to-end** with a local MailHog sink: test email delivered, and a
  real `disk-low` alert opened by the eval loop triggered a digest email
  (`[warning] ... low disk space: C: 2% free`). Test infra + config cleaned up;
  server reset to first-run.

## v3.7 UPDATES — CI agent build green end-to-end (P0) + MSI live

- **NEW: `agent-build` CI job verified end-to-end** on `windows-latest`
  (workflow_dispatch) — stages `agent-config.json` from repo secrets
  (`SERVER_ENDPOINT`, `API_TOKEN`), builds the exe via ps2exe, and the MSI via
  **WiX v5** (pinned because WiX v7 requires accepting the OSMF EULA). Both CI
  jobs now green (PowerShell validation + agent build).
- **FIX: WiX v4+ schema** — `Agent.wxs` custom actions now use the required
  `Directory` attribute with `ExeCommand` and `Condition` attributes instead of
  inner text (`REMOVE="ALL"`, `NOT Installed AND NOT REMOVE`).
- **FIX: MSI staging path** — `build-msi.ps1` runs `wix build` from the WXS
  directory (`Push-Location`), so WiX v5 resolves the relative `stage\...`
  `Source` paths against the WXS location, not the caller's CWD.
- **FIX: project-index freshness check** — `Update-ProjectIndex.ps1` hashes only
  **git-tracked files**; gitignored files present only in local working trees
  (`.env`, generated `agent-config.json`, `__pycache__`) no longer cause index
  drift → the CI `Verify project index is up to date` step is deterministic.
- **MSI is now live:** the CI-built `IT-Toolkit-Agent.msi` (with the live
  endpoint + token baked in) is copied into the server's `agent_artifacts`
  volume — `GET /api/agent-msi` returns HTTP 200 with a valid WiX installer
  (verified). The `/api/agent-msi` "404 until P0 upload" gap is closed.
- **NOTE:** `agent-build` requires the two repo secrets
  `SERVER_ENDPOINT` + `API_TOKEN` (configured in GitHub repo settings).

## v3.6 UPDATES — Alerts + reporting (P6)

- **NEW: `alert_rules` + `alerts` tables** (schema.sql + idempotent runtime
  migration) — `alert_rules` (name, description, condition jsonb, severity,
  enabled), `alerts` (rule_id, agent_id, severity, message, status open/
  acknowledged/resolved, created_at, resolved_at) + `idx_alerts_status`.
- **NEW: seeded rules** (`rules.py::seed_rules`, idempotent): agent-offline
  (15 min no report), disk-low (<10% free on a logical volume), smart-predict
  (SMART predicted failure), battery-low (<20%), service-down (critical service
  stopped), reboot-pending (>7 days uptime).
- **NEW: eval loop** — background asyncio `alert_loop()` on API startup
  (`ALERT_EVAL_MINUTES` env, default 1 min) opens an alert once per rule/agent
  while a condition fires and **auto-resolves** open/acknowledged alerts when it
  clears; a persistent condition re-opens after manual resolve.
- **NEW: alert API** — `GET /api/alerts?status=&limit=` (all roles),
  `GET /api/alerts/open` (badge count), `POST /api/alerts/{id}/ack` and
  `/resolve` (admin/operation; monitoring → 403), `GET /api/alert-rules`,
  `PUT /api/alert-rules/{name}` (admin-only; toggle enabled / severity /
  condition jsonb).
- **NEW: reports API** — `GET /api/report/fleet` (CSV, one row per agent with
  latest hardware/health/update/disk snapshot) and
  `GET /api/report/agent/{id}?format=json|csv` (all events for one agent).
- **Portal:** **Alerts** page (status filter + ack/resolve buttons, rule admin
  panel for admins) + **open-alert badge** in the nav polling `/api/alerts/open`
  every 30s; **Reports** page with fleet CSV + per-agent JSON/CSV export links.
- **Collectors:** `Get-DiskHealth.ps1` gained `logical` volume array
  (Drive/SizeGB/FreeGB/FreePercent); `Get-HardwareInventory.ps1` gained
  `battery.charge_percent` + `battery.status` — feeds the disk-low and
  battery-low rules.
- **Verified live** on `10.73.77.26`: rules seeded; disk-low/battery-low/
  reboot-pending fired from ingested fixtures; ack/resolve + RBAC (monitoring
  403, operation/admin 200); auto-resolve on condition clear; re-open on
  persistent condition; fleet CSV + agent JSON/CSV exports; test data reset to
  first-run.

## v3.5 UPDATES — Command channel / remote ops (P5)

- **NEW: `commands` table** (schema.sql + idempotent runtime migration) —
  id, agent_id, kind, payload(jsonb), status (pending/picked_up/completed/
  failed), result(jsonb), created_by, timestamps.
- **NEW: API** — `POST /api/commands` (admin/operation; monitoring → 403) issues
  reboot / wake / run-script; `GET /api/commands` audit list (all roles); agent
  `GET /api/commands/poll?hostname=...` (bearer token) marks `picked_up` and
  re-delivers within a 5-minute window; `POST /api/commands/{id}/result`
  (bearer) completes/fails the command with output + exit code.
- **NEW: run-script gating** — `COMMANDS_RUN_SCRIPT_ALLOWED=false` by default
  (403); when enabled, scripts must be in `RUN_SCRIPT_ALLOWLIST` (comma-separated
  paths), else 403.
- **Agent:** polls commands each cycle, executes (reboot via `shutdown.exe`/
  `Restart-Computer`, WOL magic packet via UDP broadcast, allowlisted scripts)
  and posts the result — verified with the full poll→execute→result flow.
- **Portal:** **Commands** page — issue form with per-kind fields + history with
  payload/result viewer; hidden for monitoring.
- **Verified live** on `10.73.77.26`: issue (reboot/wake), run-script 403 when
  disabled and allowlist 200/403 when enabled, poll/re-delivery/result, 404 on
  unknown command, 401 unauth, RBAC 403 for monitoring; test data reset.

## v3.4 UPDATES — Support-engineer collectors + fleet panels (P4)

- **NEW: 7 collectors** in `Enterprise/agent/collectors/` (each emits one JSON
  object): `hardware` (CPU/RAM/disks/GPU/BIOS/serial + **battery wear %**),
  `software`, `diskhealth` (SMART + predicted failure), `health` (uptime/load/
  reboot-pending/critical services), `bitlocker`, `updatecompliance`,
  `licenses` (**last-5 keys only**, sanitized, default off).
- **Agent:** `Agent-Collect.ps1` gains `ConvertFrom-CollectorOutput` — parses
  structured JSON from collectors, falls back to text for the legacy scripts;
  server stores real `jsonb` dicts for fleet panels.
- **Manifest single-source:** `features.json` now lists all 13 features; the
  portal toggles, the company `agent.json`, and deploy.sh's `agent-config.json`
  all derive from it (deploy.sh generates via python3 — no drift).
- **MSI:** WiX + build-msi.ps1 bundle collectors at
  `<root>\Enterprise\agent\collectors\` (same relative path as agent.json).
- **Portal:** new **Fleet** view — offline agents, disk health/SMART, battery
  wear, update compliance, system health; **licenses admin-only**.
- **Verified live** on `10.73.77.26`: manifest + bundle reflect all 13
  features; structured diskhealth/hardware ingests stored as dicts with
  predicted_failure flags; all collectors parse-checked and emit valid JSON
  (pwsh); test data reset for first-run setup.

## v3.3 UPDATES — Company agent bundle + downloads (P3)

- **NEW: server-side company bundle** — `bundle.py` assembles `agent.json`
  (endpoint = scheme+host, token, company, **live feature overrides**) + `ca.crt`
  + a generated `install-agent.cmd` (installs the MSI, then writes the company
  `agent.json` + `ca.crt` over the bundled template and sets registry overrides).
- **NEW: download endpoints** (admin/operation; monitoring → 403):
  `GET /api/agent-bundle` (everything at once), `/api/agent/agent.json`,
  `/api/agent/install.cmd`, `/api/ca.crt`, and `/api/agent-msi` — serves the
  generic engine MSI from the new **`agent_artifacts` volume**, returning 404
  until a real build is uploaded (`docker compose cp IT-Toolkit-Agent.msi api:/artifacts/`).
- **Portal:** **Agent Setup** tab now shows download buttons + live previews of
  `install-agent.cmd` and `agent.json`; deploy.sh prints the MSI upload command.
- **Verified live** on `10.73.77.26`: bundle reflects feature toggles, all
  downloads (agent.json/install.cmd/CA) stream with correct filenames, MSI
  404→200→404 with the volume, RBAC 403 for monitoring, 401 unauthenticated;
  test data reset so the setup wizard is ready for first-run.

## v3.2 UPDATES — Team users & RBAC (P2)

- **NEW: roles** — admin (everything) / operation (view + feature control +
  agent download; no user mgmt) / monitoring (read-only). `require_role()`
  dependency enforces it on every admin route; `monitoring` gets 403 on
  feature writes; non-admins never receive `agent_token`.
- **NEW: `/api/users`** (admin-only): list / create / change role / disable /
  enable / reset password. Self-disable blocked; duplicate usernames → 409;
  disabled accounts rejected at login.
- **Portal:** new **Users** tab (admin-only) with create form, role dropdown,
  disable/enable and password reset; feature config controls hidden for
  `monitoring`; dashboard bootstraps from `/api/bootstrap` (company + user).
- **Verified live** on `10.73.77.26`: user CRUD + duplicate 409, ops can read
  + toggle features but not manage users, monitoring blocked from feature
  writes, disabled login rejected, role change + password reset, self-disable
  400; test data reset so the setup wizard is ready for first-run.

## v3.1 UPDATES — First-time setup wizard + local certificates (P1)

- **NEW: setup wizard** (`Enterprise/portal/`): first visit shows company name /
  server address / first admin account / brand color; server generates everything
  locally — **local CA + server certificate** (`api_data:/data/certs`, `ca.key`
  server-only), auth token, and a **company agent template** (endpoint + token +
  CA trust). Guarded: `POST /api/setup` is one-shot (409 after), re-run is
  login-only and never touches agents/events data.
- **NEW: session auth** — `users` table + `settings` table (schema.sql + idempotent
  runtime migration in `db.py` so existing volumes upgrade without `down -v`);
  `auth.py` PBKDF2-SHA256 password hashing (120k iterations), HMAC-signed session
  cookies with a persisted `SESSION_SECRET`; admin API moved from the shared
  bearer token to session-based; `POST /api/login|logout`, `/api/me`,
  `/api/bootstrap`, `GET /api/ca.crt`, `GET /api/agent-template`.
- **NEW: `cryptography` dependency** added to `api/requirements.txt`.
- **Portal:** setup wizard → branded login → dashboard; header shows company
  branding; no shared-token input box anymore; new **Agent Setup** tab.
- **Verified live** on `10.73.77.26`: setup → login → me → bootstrap →
  agent-template → CA download → agents/events (session) → `/ingest` (bearer)
  all pass; logout invalidates session; re-setup → 409; test data reset so the
  wizard is ready for the real first-run setup.

## v3.0 UPDATES — Enterprise client-server stack (Phase 3)

- **NEW: `Enterprise/`** — fully additive scale-out layer, **zero changes** to existing scripts/modules/docs:
  - **Agent** (`Enterprise/agent/`): `Agent-Collect.ps1` wraps existing `Scripts/*.ps1`, sanitizes output via the existing `SanitizeEngine`, queues offline via SQLite, and ships sanitized JSON to the server. Packaged as `.exe` (ps2exe) + `.msi` (WiX) with the endpoint/token baked in at build time.
  - **Server** (`Enterprise/api/`, `docker-compose.yml`): FastAPI with `POST /ingest`, `/api/agents`, `/api/events`, `/api/features` (config editor) + PostgreSQL 16, behind Caddy reverse proxy. One shared DB for both the ingest API and the portal.
  - **Portal** (`Enterprise/portal/`): single-page admin UI — Agents, Events, Feature toggles/config editor.
  - **Deploy** (`Enterprise/deploy/deploy.sh`): one-command bring-up — **intranet/LAN-first by default** (auto-detects LAN IP on macOS + Linux, prefers en0/en1/eth0), `--regen` to re-point when moving machines, `--public` for internet clients; generates `.env` secrets, bakes the endpoint into `agent-config.json`, starts Docker.
  - **CI**: new `agent-build` job (windows-latest) produces the `.exe` + `.msi` artifacts from repo secrets.
- **Verified locally:** full stack smoke-tested in Docker — ingest (idempotent dedupe), auth 401, agents/events queries, feature enable/disable, portal, and a real agent→server round-trip with PII `[REDACTED-*]` sanitization.
- **FIXED (deploy verification):** event payloads were persisted as JSON *strings* — now bound as true `jsonb` objects (asyncpg `jsonb` codec registered; nested payloads round-trip as dicts via `/api/events`).
- **NEW:** API token is **auto-generated everywhere** — `deploy.sh` generates random secrets on first run, auto-regenerates any placeholder (`change-me-*`) it finds in an existing `.env`, and the API self-generates + persists (volume) + prints (once) a token if `API_TOKEN` is ever empty. No manual secret setup.
- See `Enterprise/README.md` + `Enterprise/ARCHITECTURE.md` for the blueprint.

## v2.0 UPDATES — Enhanced with comprehensive fixes & features

### 🔧 FIXES & IMPROVEMENTS
- **FIXED:** Toolkit-Menu.bat had wrong menu mappings for options 7-14 (now corrected)
- **COMPLETED:** Firewall-Test.ps1 was incomplete - now fully functional with proper reporting
- **ENHANCED:** User-Inventory.ps1 now includes BIOS info, Windows updates, and better formatting

### 📚 NEW DOCUMENTATION (COMPREHENSIVE)
- **Scripts/README.md** — Complete 25+ page reference for all 7 scripts
  - What each script does, when to use it, how to run it
  - Admin requirements, output format, configuration options
  - Troubleshooting common script issues
  - Performance characteristics and version history

- **Documentation/README.md** — Master index for all documentation
  - How to find what you need quickly
  - Task-based navigation (by problem type)
  - Time-based navigation (1 min vs 30 min reads)
  - Complete status of all documentation

### 🤖 AI ASSISTANT PROMPTS — MASSIVELY EXPANDED
- **Before:** 7 basic prompts
- **After:** 33 comprehensive, organized prompts
- **Sections:** Troubleshooting, PowerShell help, Security, Updates, Remote access, Hardware, Software, Documentation writing
- **Coverage:** Error analysis, event logs, network issues, commands, registry editing, firewall rules, performance, and much more
- **Location:** Templates/AI-Assistant-Prompts.txt

### ⚙️ CONFIGURATION — FULLY ENHANCED
- **Before:** config.json had only 2 example machines
- **After:** Comprehensive configuration with 15+ customization categories
- **New options:**
  - Network settings (DNS, test hosts)
  - Remote access configuration (RDP, SSH)
  - Script defaults (logging, retention, admin requirements)
  - Security settings
  - Firewall test customization (custom ports)
  - Event log settings
  - User inventory customization
  - UI preferences

### 🧙 SETUP WIZARD — NEW FEATURE
- **Setup-Wizard.bat** — Interactive guided setup for first-time users
- **Features:**
  - Quick setup (verify files, set PowerShell policy)
  - Configure machines (add your servers/PCs)
  - Configure network settings
  - Configure script defaults
  - Verify all files present
  - Test PowerShell execution
  - Open/edit config file
  - View documentation
  - Interactive menu (not command-line)

### ⚙️ OPERATIONS (verified 2026-08-05)
- ✓ Git repository initialized with clean commit history
- ✓ `.gitignore` added (`.DS_Store`, logs, temp files) — `.DS_Store` removed from tracking
- ✓ CI pipeline added: `.github/workflows/ci.yml` (PowerShell parse, JSON validation, regression suite, PSScriptAnalyzer on Windows)
- ✓ Deduplicated config bootstrap into shared `Scripts/Modules/ToolkitConfig.psm1`
- ✓ Secure config defaults (encryption on, HTTPS WinRM) and credential-vault guidance

### 🤖 AUTO-INDEX (added 2026-08-06, verified 2026-08-06)
- ✓ `Scripts/Index/Update-ProjectIndex.ps1` — incremental auto-indexer maintaining `project-index.json`, `project-state.json`, `project-progress.json`
- ✓ Detects added/removed/changed files via SHA-256 snapshot deltas; preserves issue/resolution/risk history
- ✓ Idempotent regeneration: only records a delta when the tree actually changes, so repeated runs are byte-stable
- ✓ `-Check` mode for CI: regenerates and compares meaningful content against HEAD (ignoring timestamps + git identity), restores files when fresh
- ✓ `Scripts/Index/Install-GitHook.ps1` — installs the pre-commit hook (`.githooks/pre-commit`) so every commit refreshes the index
- ✓ CI now verifies the project index is up to date (`Verify project index is up to date` step via `-Check`)
- ✓ Verified end-to-end: add scenario (`added: 1`), remove scenario (`removed: 1`), and change scenario all captured in delta history

### ✅ QUALITY ASSURANCE (verified 2026-08-05)
- ✓ Phase 1 regression suite passes (CSV/JSON/HTML export, alert thresholds, log cleanup)
- ✓ RemoteToolkit.psm1 imports and exports all 6 functions
- ✓ Toolkit-Menu.bat reads user input and maps all menu options
- ✓ Firewall-Test.ps1 no longer overwrites the read-only `$host` variable
- ✓ CredentialManager stores/retrieves credentials without exposing plaintext passwords
- ✓ Remote script execution no longer uses `-ExecutionPolicy Bypass`
- ✓ No duplicate files or entries
- ✓ Configuration consistency verified

### 🧪 PHASE 2 — HARDENING + NEW SURFACES (added & verified 2026-08-06)
- **SanitizeEngine.psm1** — PII redaction (emails, IPs, accounts, hostnames); wired into `Export-EventLogs.ps1`; config-driven toggles in `config.json`
- **ToolkitData.psm1** — cross-platform SQLite persistence via `sqlite3` CLI (inventory / diagnostics / schema); `Data/DATABASE-GUIDE.md`, `Data/README.txt`
- **TaskScheduler.psm1** — cron-style recurrence builder + `schtasks.exe` wrapper with Windows-only guard; `SCHEDULE-GUIDE.md`
- **CredentialManager** — canonical `Save-ToolkitCredential` (alias `Store-ToolkitCredential` retained); import is unapproved-verb clean
- **GUI dashboard** — `Scripts/GUI/Toolkit-GUI.ps1` WinForms launcher (Windows-only, guarded exit 2 on macOS); `DASHBOARD-GUIDE.md`
- **Docs** — `Config/CONFIG-GUIDE.md`, `VERSION.md` (v1.0.0 release reference)
- **Tests** — NEW `BatchLauncher.Tests.ps1` (batch control-flow 9/9), `Phase2-Modules.Tests.ps1` (11/11) — all green locally
- **CI** — Pester suites (RemoteToolkit, BatchLauncher, Phase2 modules) added to `ci.yml`
- **Release** — annotated tag `v1.0.0` created

### 🚀 PUBLISHED TO GITHUB + CI GREEN (verified 2026-08-06)
- ✓ Connected remote: `origin` → `https://github.com/j9619655391-max/Aaditech-ToolKit` (public)
- ✓ Pushed `main` + annotated tag `v1.0.0`
- ✓ GitHub Actions CI **green on `windows-latest`** — all 9 steps pass:
  PowerShell parse (30 files), JSON validation, Phase 1 regression, Pester suites,
  PSScriptAnalyzer (0 errors), project-index freshness
- **CI-blocking fixes made during first runs:**
  - `audit/audit-engine.ps1` — invalid `[...]` array syntax → `@(...)`
  - Suppressed intentional PSScriptAnalyzer findings (`8.8.8.8` reachability target,
    trusted vault reconstruction, synthetic test fixtures) via `[SuppressMessageAttribute] param()`
  - Indexer made cross-platform deterministic:
    - normalized LF line endings in hashes (Windows checkout applies CRLF to `.bat`/`.cmd`)
    - stripped Windows path separators so relative paths are identical
    - sorted `files`/`modules`/`scripts` arrays (macOS vs NTFS enumeration order differs)
  - `.gitattributes` added (LF for text/code, CRLF for batch files)

---

## v2.0 — Original Release
Added everything missing from v1:
- `Toolkit-Menu.bat` — single master launcher for every tool in the kit
- `Remote-Tools/` folder — RDP shortcut generator + remote access reference
- `Scripts/Printer-Fix.ps1` — dedicated printer/spooler repair script
- `Scripts/Pin-QuickAccess-Folders.ps1` — automates pinning common folders
- `Scripts/Export-EventLogs.ps1` — exports sanitizable event log excerpts for tickets
- `Scripts/User-Inventory.ps1` — comprehensive hardware/software inventory
- `Scripts/Firewall-Test.ps1` — Windows Firewall status & connectivity testing
- `Templates/CMD-Commands-Reference.txt` — dedicated CMD reference
- `Templates/AI-Assistant-Prompts.txt` — ready-to-use AI chat prompts
- `Software/Portable-Software-Links.md` — verified official download links
- `Config/config.json` — centralized configuration for all scripts

## v1.0 — Initial release
- Folder structure, QuickCheck.ps1 menu script, Network-Diagnostic.ps1
- Knowledge-Base.xlsx (3 tabs), Ticket-Reply-Templates.txt
- Setup-Guide.md, Cheat-Sheet.md, Troubleshooting-Flowcharts.md

- Auto-index verified working
