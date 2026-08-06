# Changelog

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
