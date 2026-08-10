# IT-Toolkit — Version Reference

**Current release:** `v1.3.0`
**Release date:** 2026-08-09
**Branch:** `main`
**Repository:** https://github.com/j9619655391-max/Aaditech-ToolKit
**Remote:** `origin` (GitHub, public) — `main` + `v1.0.0`, `v1.1.0`, `v1.2.0`, `v1.3.0` tags pushed
**CI status:** ✅ green on `windows-latest` — PowerShell validation + **agent exe/MSI build** (WiX v5) both pass end-to-end; **API pytest smoke suite** (vs Postgres service) added in this release.

> **v1.3.0 = Enterprise hardening (SCALING-PLAN A–E)**: least-privilege agent
> task (NETWORK SERVICE + on-demand elevated helper, E4), agent heartbeat /
> queue pruning / self-update (E1–E3), metrics + structured logs + audit log
> (D1–D3), transactional ingest + setup, at-most-once commands, cert renewal,
> backup/restore (C1–C6), RBAC + ratelimit + TLS + secrets-at-rest (B1–B6),
> and the A1–A7 foundation fixes. Added an AI-agent prerequisite scanner +
> deployment runbook and an API pytest suite.
>
> **v1.2.0 = SaaS-style auto-setup (Rev 3)**: everything is auto-detected /
> auto-generated on ANY server; the only manual step is the setup wizard
> (company / admin / SMTP / build mode). `deploy.ps1` (Windows Server) builds +
> signs + publishes the MSI locally; `deploy.sh` (macOS/Linux) + the setup
> wizard's **GitHub remote-build mode** trigger `ci.yml` via `workflow_dispatch`
> and auto-download the signed MSI. Agents auto-trust the server CA on enroll.

## What is this document?
A single source of truth for the toolkit's version, module inventory, and
verification status. It complements `CHANGELOG.md` (what changed) by recording
*what ships in this version* and *how it was verified.*

## Versioning
This project follows a lightweight manual `vX.Y.Z` tag scheme (no tooling).
The version is stamped as a git tag and referenced from the GUI footer, docs,
and this file.

- Increment `MAJOR` on breaking structural/API changes.
- Increment `MINOR` on new features.
- Increment `PATCH` on fixes and hardening.

## Module inventory (Scripts/Modules)
| Module | Purpose | Status |
| --- | --- | --- |
| `AlertEngine.psm1` | Threshold/severity alerting | verified |
| `CredentialManager.psm1` | DPAPI-backed credential vault | verified (verb-clean) |
| `ExportEngine.psm1` | CSV/JSON/Excel-compatible export | verified |
| `LogManager.psm1` | Log retention/cleanup | verified |
| `RemoteToolkit.psm1` | Remote execution (WinRM) | verified (export + guards) |
| `ReportGenerator.psm1` | HTML report generation | verified |
| `SanitizeEngine.psm1` | PII redaction (emails/IPs/accounts/hostnames) | verified (new in this release) |
| `TaskScheduler.psm1` | Cron-style recurrence + schtasks wrapper | verified (new in this release) |
| `ToolkitConfig.psm1` | Centralized config bootstrap | verified |
| `ToolkitData.psm1` | SQLite persistence layer (sqlite3 CLI) | verified (new in this release) |

## Application surfaces
- `Toolkit-Menu.bat` / `Setup-Wizard.bat` — batch launchers (cmd.exe)
- `Scripts/GUI/Toolkit-GUI.ps1` — WinForms dashboard (Windows-only, new)
- `Scripts/*.ps1` — individual diagnostic/export tools

## Test coverage (v1.0.0)
| Suite | File | Result |
| --- | --- | --- |
| Phase 1 regression | `Scripts/Tests/Phase1-Regression.Tests.ps1` | PASS (standalone) |
| RemoteToolkit | `Scripts/Tests/RemoteToolkit.tests.ps1` | PASS 5/5 |
| Batch control-flow | `Scripts/Tests/BatchLauncher.Tests.ps1` | PASS 9/9 |
| Phase 2 modules | `Scripts/Tests/Phase2-Modules.Tests.ps1` | PASS 11/11 |

## Enterprise stack (Phase 3, new)
See `Enterprise/README.md` and `Enterprise/ARCHITECTURE.md`. Additive, zero
changes to the local toolkit.

- **Server (Docker):** FastAPI (`/ingest`, `/api/*`) + PostgreSQL 16 + Caddy TLS, one shared DB.
- **Agent:** `Enterprise/agent/Agent-Collect.ps1` → packaged `.exe` (ps2exe) + `.msi` (WiX). Runs existing scripts + P4 collectors, sanitizes (reuses `SanitizeEngine`), queues offline (reuses `ToolkitData`), posts HTTPS; auto-parses structured collector JSON.
- **Collectors (P4):** `Enterprise/agent/collectors/` — hardware (battery wear %), software, diskhealth (SMART), system health, BitLocker, update compliance, licenses (last-5 only, default off). Bundle served via `/api/agent-bundle`; portal Fleet panels (offline / disk / battery / updates / health).
- **Portal:** first-time **setup wizard** (company / server / admin / branding → local CA + server certs + token) + branded login + admin UI (Agents / Events / Feature config editor / Users with RBAC roles / Agent Setup with company bundle downloads).
- **Deploy:** `Enterprise/deploy/deploy.sh` — **intranet/LAN-first** (auto-detects LAN IP on macOS + Linux), `--regen` to re-point on a new machine, `--public` for internet clients; bakes endpoint+token into the agent config, brings up Docker. **Secrets auto-generated** (API token + Postgres password); API self-generates/persists a token if `API_TOKEN` is empty.
- **Agent bundle (P3):** `GET /api/agent-bundle` assembles company `agent.json` + `ca.crt` + live `install-agent.cmd`; downloads at `/api/agent/agent.json`, `/api/agent/install.cmd`, `/api/ca.crt`, `/api/agent-msi` (MSI served from the `agent_artifacts` volume; 404 until the CI generic build is uploaded).
- **Commands (P5):** `commands` table; `POST /api/commands` (admin/operation), `GET /api/commands` (all roles), agent `GET /api/commands/poll` + `POST /api/commands/{id}/result` (bearer token). Kinds: reboot (delay), wake (WOL), run-script (allowlist + flag). Portal Commands page with history/audit.
- **Alerts (P6):** `alert_rules` + `alerts` tables; seeded rules (offline 15 min, disk <10%, SMART predicted failure, battery <20%, service down, reboot-pending >7 days); background eval loop (`ALERT_EVAL_MINUTES`, default 1 min) auto-opens/resolves; ack/resolve + RBAC (admin/operation; monitoring read-only). Portal Alerts page (filter + rule admin) + open-alert badge. **Optional SMTP alert email** (P6.1, `SMTP_HOST`+`SMTP_TO` in `.env`) + `POST /api/alerts/test-email` admin check — verified with a local MailHog sink.
- **Reports (P6):** `GET /api/report/fleet` (CSV, one row per agent with latest hardware/health/update snapshot), `GET /api/report/agent/{id}?format=json|csv`. Portal Reports page with export links.
- **P0 agent build (verified 2026-08-07):** CI `agent-build` job now runs green end-to-end — stages `agent-config.json` (from repo secrets `SERVER_ENDPOINT` + `API_TOKEN`), builds the exe via ps2exe, and the MSI via **WiX v5** (pinned; v7 requires OSMF EULA). Artifacts uploaded; the MSI is deployed into the server's `agent_artifacts` volume so `GET /api/agent-msi` returns a real installer.
- **Indexer fix:** `Update-ProjectIndex.ps1` hashes only **git-tracked files** (ignores `.env`, generated `agent-config.json`, `__pycache__`), so the CI freshness check no longer drifts between local working trees and fresh clones.
- **CI:** new `agent-build` job (windows-latest) builds `.exe` + `.msi` artifacts.
- **Verified locally:** full Docker stack + agent→server round-trip with PII `[REDACTED-*]` sanitization (macOS smoke).

CI (`ci.yml`) runs on `windows-latest` and is **green**: PowerShell parse
(all `.ps1`/`.psm1` files), JSON validation, Phase 1 regression, Pester suites (RemoteToolkit,
BatchLauncher, Phase2 modules), the API pytest suite (vs Postgres 16), PSScriptAnalyzer (0 errors),
and project-index freshness (`-Check`).

## Manual smoke-run items (Windows-only)
The following cannot be end-to-end verified on a macOS dev host and require a
one-time manual smoke run on a Windows machine before deployment:

- Execute `Toolkit-Menu.bat` / `Setup-Wizard.bat` under a real `cmd.exe`
- End-to-end RemoteToolkit (WinRM) against a live target
- Interactive WinForms GUI (`Scripts/GUI/Toolkit-GUI.ps1`)
- Authenticode signing of shipped scripts
- `schtasks.exe` registration via `Register-ToolkitScheduledTask`

> Full step-by-step instructions: `Documentation/Windows-Smoke-Run.md`