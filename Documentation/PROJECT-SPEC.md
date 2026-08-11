# IT-Toolkit - Project Spec (Clean-Room Conceptual Specification)

> **Purpose:** This document describes the complete IT-Toolkit platform **by
> concept** - what each part does, why it exists, how it should behave, and the
> clean design-level contracts between components. It is written to let a
> developer (human or AI agent) rebuild the platform **fresh and correct**,
> without inheriting any existing implementation bugs or mismatches.
>
> It is intentionally **not** a copy of the current source. Every feature below
> is expressed as design intent; where the current code has known pitfalls
> (e.g. repo-URL normalization, NULL-company visibility, file-encoding
> issues), they are folded in as **design rules**, not ported as bugs.
>
> **How to use:** read Part 0 first, then each layer's concepts + contracts.
> Part 6 gives acceptance checks that define "the build is correct".

---

## Part 0 - Project Philosophy

### 0.1 What the platform is

Three additive layers:

```
Layer 1  Base Windows Toolkit      standalone scripts + GUI + WinRM remote tools
Layer 2  Enterprise Agent          packaged PowerShell collectors -> exe/MSI
Layer 3  Enterprise Server         FastAPI + PostgreSQL + Caddy + web portal
```

The Enterprise layers (2 and 3) are **additive**: they wrap and extend the
existing toolkit without changing its standalone behavior. A technician can
still use the toolkit directly on a PC; the Enterprise agent just also ships
the collected data to the central server.

### 0.2 Design principles

1. **Additive, zero-change:** the base toolkit keeps working as-is; the agent
   calls its existing scripts for data collection.
2. **LAN/intranet-first:** default deployment advertises the server's LAN IP so
   same-network clients reach it. Internet exposure is an opt-in mode.
3. **Agent identity is the trust root:** every agent authenticates with an
   mTLS client certificate signed by a locally-generated CA, plus a per-agent
   bearer token after first enrollment.
4. **Clean contracts, explicit behavior:** each component has a defined input
   and output; the server is the single source of truth for state.
5. **Security by default:** PII sanitized at the source, secrets encrypted at
   rest, least-privilege execution, admin-only sensitive endpoints.

### 0.3 How contracts are written in this spec

- **Entity** = a persistent object (table) with its fields and relationships.
- **API area** = a group of endpoints with method / path / purpose / role gate.
- **Payload shape** = the JSON fields a collector or endpoint produces.
- **Protocol flow** = the sequence of requests between agent and server.

---

## Part 1 - Layer 1: Base Windows Toolkit

### 1.1 Concept

A set of PowerShell diagnostic/repair tools driven by batch launchers
(`Toolkit-Menu.bat`, `Setup-Wizard.bat`). The menu exposes ~17 numbered
options: local tools, remote tools, and a GUI dashboard. Everything is
PowerShell-first so it runs with the Windows PowerShell 5.1 present on any
admin machine, with no external dependencies beyond what ships with Windows
plus `sqlite3` (bundled) for local data.

### 1.2 Tools and their concepts

| Tool | Concept |
|---|---|
| QuickCheck | One-shot system health + inventory snapshot for a machine |
| Export-EventLogs | Export System/Application/Security logs, **sanitized** (strip usernames, IPs, paths that look sensitive) |
| Network-Diagnostic | IP config, DNS resolution, ping, connectivity checks |
| Firewall-Test | Validate Windows Firewall status and rules |
| User-Inventory | Enumerate local users and groups (needs elevation) |
| Printer-Fix | Detect and repair common printer issues (needs elevation) |
| Pin-QuickAccess | Pin folders into Explorer Quick Access |

**Remote tools (WinRM):** remote QuickCheck, remote network diagnostic, and
batch scan across multiple machines in parallel.

**Modules (shared libraries):**

| Module | Concept |
|---|---|
| SanitizeEngine | Strip PII from free text before it is stored or exported |
| CredentialManager | Store secrets in a Windows DPAPI vault (never plaintext) |
| ToolkitData | Local sqlite store for inventory snapshots |
| ExportEngine | Uniform CSV/JSON/HTML export of results |
| ReportGenerator | Human-readable report assembly |
| RemoteToolkit | WinRM connection + parallel remote invocation |
| TaskScheduler | Register scheduled runs of any tool |
| AlertEngine | Local alert evaluation against collected data |
| LogManager | Consistent log/rotation for toolkit runs |
| ToolkitConfig | Read/merge config files and defaults |

### 1.3 Contracts (design level)

- Every tool: **input** = a target (local or remote host), optional params;
  **output** = one structured result object plus a log line.
- Sanitization is applied at **write time** (before storage/export), and each
  output declares whether it is `sanitized: true/false`.
- GUI dashboard is Windows-only; headless environments get exit code 2.

---

## Part 2 - Layer 2: Enterprise Agent

### 2.1 Concept

A small Windows service-style client installed via an MSI. It runs on a
schedule as a low-privilege account (`NETWORK SERVICE`), invokes collectors,
and ships the results to the server over a mutually-authenticated TLS channel.
Administrative actions (licensed collectors, MSI self-upgrade, scheduled
reboot) are staged to an on-demand elevated task that the unprivileged agent
can trigger but not bypass.

### 2.2 Collector features

Each collector produces **one event** per cycle. `default` = enabled on a
fresh install; `elevated` = runs in the elevated task.

| Collector | kind | default | elevated | Data produced |
|---|---|---|---|---|
| System Quick Check | `quickcheck` | on | no | health + inventory snapshot |
| Event Logs | `eventlogs` | on | no | sanitized system/app/security logs |
| Network Diagnostics | `network` | on | no | IP/DNS/ping/connectivity |
| Firewall Audit | `firewall` | on | no | firewall status + rules |
| Hardware Inventory | `hardware` | on | no | CPU, RAM, disks, GPU, BIOS, serial, battery wear % |
| Software Inventory | `software` | on | no | installed apps + versions |
| Disk Health | `diskhealth` | on | no | physical disk health + SMART failure prediction |
| System Health | `health` | on | no | uptime, CPU/RAM %, reboot-pending, critical services |
| Update Compliance | `updatecompliance` | on | no | last Windows Update activity |
| User Inventory | `users` | off | yes | local users/groups |
| Printer Diagnostics | `printers` | off | yes | printer state/issues |
| BitLocker Status | `bitlocker` | off | yes | volume encryption state |
| License Info | `licenses` | off | yes | **Windows/Office key last-5 chars only** (never full keys) |

**Payload shape (all collectors):**

```json
{
  "kind": "health",
  "payload": { "...feature fields..." },
  "captured_at": "ISO-8601 timestamp",
  "client_msg_id": "unique id for at-most-once delivery"
}
```

### 2.3 Agent lifecycle concepts

- **Heartbeat:** a cheap liveness ping (hostname + OS/IP/version) that keeps
  `last_seen` fresh and lets the server detect offline agents.
- **Enrollment / token:** on first contact the agent receives a per-agent
  bearer token; the shared fleet token is retired for that agent.
- **Commands:** the agent polls for pending commands and executes:
  - `reboot` - schedule a reboot (elevated)
  - `wake` - Wake-on-LAN
  - `run-script` - only scripts on a server-side allowlist, gated by config
- **Self-update:** the agent checks a rollout target version; if the MSI is
  newer it downloads and installs it silently (elevated).
- **Revocation:** an operator can revoke an agent; revoked agents are rejected
  even with a valid token.
- **Resilience:** exponential backoff with jitter on delivery failure, bounded
  outbox, dedupe via `client_msg_id` so a retried batch is not double-counted.

### 2.4 Agent -> server protocol (design level)

| Flow | Endpoint (conceptual) | Direction | Auth |
|---|---|---|---|
| Heartbeat | `POST /api/agent/heartbeat` | agent -> server | agent token + mTLS |
| Ingest events | `POST /ingest` | agent -> server | agent token + mTLS |
| Poll commands | `GET /api/commands/poll?hostname=` | server <- agent | agent token + mTLS |
| Command result | `POST /api/commands/{id}/result` | agent -> server | agent token + mTLS |
| Update check | `GET /api/agent/update` | agent -> server | agent token + mTLS |
| MSI download | `GET /api/agent/msi` | agent -> server | agent token + mTLS |

**Design rule:** the server must reject batches that are malformed, exceed the
body/event limits, or carry a duplicate `client_msg_id` (rollback the batch).
Licensed events (`licenses`) must be gated so only admins can read them.

---

## Part 3 - Layer 3: Enterprise Server

### 3.1 Concept

A single-host Docker stack: **API (FastAPI) + PostgreSQL + Caddy**. Caddy
serves the web portal on `:80/:443` and an mTLS-only agent port (e.g. `:9443`).
The API is the single source of truth for agents, events, alerts, commands,
users, and companies.

### 3.2 Data model (clean design)

| Entity | Purpose | Key relationships |
|---|---|---|
| `agents` | one row per enrolled machine | unique hostname; belongs to a company; has token + last_seen |
| `events` | one row per collected event | FK agent; unique `client_msg_id`; indexed `(kind, agent_id, captured_at)` |
| `feature_configs` | per-feature on/off + config | keyed by feature name |
| `settings` | key/value server settings | secrets stored encrypted |
| `users` | portal accounts | unique username; role; belongs to a company |
| `commands` | command queue | FK agent; status pending/picked_up/completed; result payload |
| `alert_rules` | evaluatable rules | name unique; condition JSONB; severity; enabled |
| `alerts` | opened alerts | FK rule + agent; status open/acknowledged/resolved |
| `audit_log` | security-relevant trail | user, action, target, IP, detail |
| `companies` | tenants (multi-tenant) | agents + users belong to one; one default |

**Design rules:**
- Agents/users **always** have a `company_id` (F4). Rows without one
  (legacy/pre-tenant data) are treated as **unassigned** and remain visible to
  every company user: scope clause is `company_id = <mine> OR company_id IS NULL`.
  Cross-tenant isolation must still hold (another company's agents are never
  visible).
- Startup-only migrations: schema applied at boot, no destructive auto-changes.
- Index for "latest event per agent" lookups (software/license compliance).

### 3.3 API surface (areas + role gates)

| Area | Purpose | Example endpoints | Role gate |
|---|---|---|---|
| Setup | one-shot first-run wizard | `GET/POST /api/setup*` | open (pre-setup only) |
| Auth | login/logout/me/bootstrap | `POST /api/login`, `GET /api/me`, `GET /api/bootstrap` | session |
| Users | portal accounts CRUD | `GET/POST/PUT /api/users*` | admin/operation |
| Agents | list, token, revoke | `GET /api/agents*`, `POST /api/agents/{id}/revoke` | session / admin |
| Ingest | agent events | `POST /ingest` | agent token + mTLS |
| Events | read collected events | `GET /api/events` | session (licenses = admin) |
| Commands | create/poll/result | `GET/POST /api/commands*` | session / agent |
| Alerts | rules, open, ack/resolve, channels | `GET /api/alerts*`, `PUT /api/alert-rules/{name}` | session / admin |
| Software (F3) | search/export/compliance | `GET /api/software/*`, `GET /api/license/*` | session / admin |
| Reports | fleet + per-agent summary | `GET /api/report/*` | session |
| Features | toggle collectors | `GET/PUT /api/features*` | session / admin |
| Companies (F4) | tenants + default | `GET/POST /api/companies`, `GET/POST /api/settings/default-company` | admin |
| Build | remote MSI build | `GET/POST /api/build/*` | admin/operation |
| Ops | health/metrics/status/audit | `GET /healthz`, `GET /metrics`, `GET /api/audit` | open / session / admin |

**Auth model concepts:**
- Portal: session cookie; three roles - `admin`, `operation`, `monitoring`.
- Agent: mTLS client cert + per-agent bearer token.
- Secrets-at-rest: SMTP passwords and GitHub PATs are encrypted (Fernet-style
  vault), never stored plaintext.
- Rate limit login attempts and lock out a user after repeated failures.

### 3.4 Web portal (10 tabs)

| Tab | Concept |
|---|---|
| Agents | list of enrolled machines (hostname/OS/IP/version/last-seen) |
| Fleet | live health, disk, hardware, update compliance, offline detection |
| Events | full event history + raw JSON viewer |
| Commands | send reboot/wake/script, see delivery + result |
| Alerts | rule management + delivery config (SMTP/webhook/Slack/Teams) + live test |
| Software | fleet app search + CSV export + license compliance (F3) |
| Reports | fleet summary + per-agent detail |
| Features | toggle any collector on/off |
| Users | user CRUD + Companies manager (multi-tenant) |
| Agent Setup | MSI status, GitHub remote build, install-agent.cmd, CA download |

### 3.5 Multi-tenant (F4) - concept

Setup creates a **company** and binds the admin to it. New agents enroll into
the **current default company**. All list queries are scoped to the caller's
company. Admins can create companies, list the directory (with user/agent
counts), and repoint the default. `bootstrap` returns the caller's tenant and
(for admins) the company directory.

### 3.6 Alerts - concept

Rules are stored with a JSONB condition. A background evaluator runs each rule
against each agent's latest events and **opens an alert once** (no duplicates
for the same pair while open) and **resolves it when the condition clears**.

Built-in rules:
- `agent-offline` - no heartbeat within N minutes (warning)
- `disk-low` - logical disk free below N% (warning)
- `smart-predict` - SMART imminent failure (critical)
- `battery-low` - charge below N% (warning)
- `service-down` - critical auto-start service stopped (warning)
- `reboot-pending` - pending reboot + high uptime (info)

Delivery channels (configurable + live-testable):
- SMTP email
- Generic JSON webhook
- Slack incoming webhook (blocks format)
- Microsoft Teams connector (MessageCard)

**Design rule:** delivery runs in a background worker so the evaluation loop
is never blocked by a slow SMTP/webhook call.

### 3.7 Software inventory + license compliance (F3) - concept

- **Search:** fleet-wide case-insensitive search by app name/publisher across
  each agent's latest `software` event; empty query lists all.
- **Export:** CSV of hostname + apps.
- **Compliance (admin-only):** per-agent Windows/Office key **last-5 chars**
  and whether each is present; CSV export available. Full keys never leave the
  agent.

### 3.8 GitHub remote MSI build - concept

A Linux/macOS host cannot build a Windows MSI locally, so the server can
trigger this repo's CI (`workflow_dispatch`), poll the run, and auto-fetch the
finished `IT-Toolkit-Agent.msi` artifact into the artifacts volume, served at
`/api/agent-msi`.

**Design rule (anti-hallucination):** the repo identifier must be normalized
to canonical `owner/repo` on save **and** on every API call. Accept full URLs
(`https://github.com/OWNER/REPO.git`), `git@github.com:` form, trailing `/`,
and `.git` suffixes; never build an API path like
`/repos/https://github.com/...`.

---

## Part 4 - Deployment

### 4.1 Bring-up concept

- **`deploy.sh` (macOS/Linux):** detects LAN IP (or `--public`), generates
  `.env` secrets, writes `agent-config.json` (mTLS endpoint + token), runs
  `docker compose up -d --build`, waits for health, prints next steps.
- **`deploy.ps1` (Windows 10/11 only):** same bring-up plus local agent build
  (ps2exe + WiX) and publish.

### 4.2 Build modes

| Mode | Who builds the MSI | When to use |
|---|---|---|
| `local_windows` | the Windows server (deploy.ps1) | Windows 10/11 host |
| `github` | GitHub Actions, fetched back | Linux/macOS host |
| `manual` | operator builds elsewhere + uploads | anything |

### 4.3 Env contract (design level)

| Var | Concept |
|---|---|
| `DATABASE_URL` | Postgres connection |
| `SERVER_HOST` | advertised host/IP (auto-detect default) |
| `API_TOKEN` | shared fleet token fallback until per-agent tokens exist |
| `SESSION_SECRET` | rotated at first setup; encrypts stored secrets |
| `ENVIRONMENT` | `prod` hides API docs; `dev` exposes them |
| `COMMANDS_RUN_SCRIPT_ALLOWED` + `RUN_SCRIPT_ALLOWLIST` | gate `run-script` |
| `SMTP_*` | email delivery defaults |
| `WEBHOOK_*` | webhook delivery defaults |
| `MAX_*` | ingest/list/body limits (abuse bounds) |

---

## Part 5 - Security model

- **Two trust boundaries:** (a) portal users via session cookies + RBAC;
  (b) agents via mTLS client certs (locally-issued CA) + per-agent tokens.
- **CA + cert lifecycle:** server generates a code-signing CA; agent client
  certs auto-renew before expiry.
- **PII:** sanitized at the collector; sensitive payloads (licenses) are
  admin-only and show last-5 chars only.
- **Secrets:** encrypted at rest (Fernet-style vault), secrets files with
  restrictive permissions (0600 / icacls).
- **Audit:** security-relevant actions logged (login, setup, user, command,
  agent, feature, build) and admin-only to read.
- **Encodings:** all new files are ASCII-safe; PowerShell 5.1 parses no-BOM
  UTF-8 as CP1252, so non-ASCII bytes (e.g. em-dash 0x94) can break parsing.

---

## Part 6 - Acceptance checklist (the build is correct if...)

**Layer 1 (toolkit):**
- [ ] All ~17 menu options launch the intended tool and return to the menu.
- [ ] Sanitization strips PII before any export.
- [ ] GUI dashboard is Windows-gated; headless returns exit code 2.

**Layer 2 (agent):**
- [ ] 13 collectors emit well-formed `{kind, payload, captured_at, client_msg_id}` events.
- [ ] Elevated collectors (users/printers/bitlocker/licenses) run only elevated.
- [ ] Heartbeat keeps `last_seen` fresh; offline detection fires within the rule window.
- [ ] A duplicate `client_msg_id` batch is rejected (no double-count).
- [ ] Command poll -> execute -> result round-trips; revoked agent is rejected.
- [ ] Self-update installs the newer MSI silently when target version advances.

**Layer 3 (server):**
- [ ] Setup is one-shot and transactional (crash never leaves half-configured).
- [ ] RBAC holds: monitoring cannot read licenses/audit; admin-only writes gated.
- [ ] F4 isolation: a Beta-company agent is invisible to an ACME admin; unassigned (NULL company) rows remain visible.
- [ ] Alert rules open once and resolve when the condition clears; email + webhook/Slack/Teams deliver.
- [ ] Software search/export + license compliance return correct, admin-gated results.
- [ ] GitHub build: full-URL repo normalizes to `owner/repo`; validate/trigger/status work with no `/repos/https://...` 404.
- [ ] `/healthz` and `/metrics` respond; audit log records actions.

---

*End of spec. This document is concept-and-contract level: rebuild from here,
verify against Part 6, and treat the current source only as a reference, not
as the definition of correct behavior.*
