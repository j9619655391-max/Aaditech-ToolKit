# IT-Toolkit — Version Reference

**Current release:** `v1.0.0`
**Release date:** 2026-08-06
**Branch:** `main`
**Repository:** https://github.com/j9619655391-max/Aaditech-ToolKit
**Remote:** `origin` (GitHub, public) — `main` + `v1.0.0` tag pushed
**CI status:** ✅ green on `windows-latest` (all 9 steps, verified 2026-08-06)

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
- **Agent:** `Enterprise/agent/Agent-Collect.ps1` → packaged `.exe` (ps2exe) + `.msi` (WiX). Runs existing scripts, sanitizes (reuses `SanitizeEngine`), queues offline (reuses `ToolkitData`), posts HTTPS.
- **Portal:** first-time **setup wizard** (company / server / admin / branding → local CA + server certs + token) + branded login + admin UI (Agents / Events / Feature config editor / Users with RBAC roles / Agent Setup with company bundle downloads).
- **Deploy:** `Enterprise/deploy/deploy.sh` — **intranet/LAN-first** (auto-detects LAN IP on macOS + Linux), `--regen` to re-point on a new machine, `--public` for internet clients; bakes endpoint+token into the agent config, brings up Docker. **Secrets auto-generated** (API token + Postgres password); API self-generates/persists a token if `API_TOKEN` is empty.
- **Agent bundle (P3):** `GET /api/agent-bundle` assembles company `agent.json` + `ca.crt` + live `install-agent.cmd`; downloads at `/api/agent/agent.json`, `/api/agent/install.cmd`, `/api/ca.crt`, `/api/agent-msi` (MSI served from the `agent_artifacts` volume; 404 until the CI generic build is uploaded).
- **CI:** new `agent-build` job (windows-latest) builds `.exe` + `.msi` artifacts.
- **Verified locally:** full Docker stack + agent→server round-trip with PII `[REDACTED-*]` sanitization (macOS smoke).

CI (`ci.yml`) runs on `windows-latest` and is **green**: PowerShell parse
(30 files), JSON validation, Phase 1 regression, Pester suites (RemoteToolkit,
BatchLauncher, Phase2 modules), PSScriptAnalyzer (0 errors), and project-index
freshness (`-Check`).

## Manual smoke-run items (Windows-only)
The following cannot be end-to-end verified on a macOS dev host and require a
one-time manual smoke run on a Windows machine before deployment:

- Execute `Toolkit-Menu.bat` / `Setup-Wizard.bat` under a real `cmd.exe`
- End-to-end RemoteToolkit (WinRM) against a live target
- Interactive WinForms GUI (`Scripts/GUI/Toolkit-GUI.ps1`)
- Authenticode signing of shipped scripts
- `schtasks.exe` registration via `Register-ToolkitScheduledTask`

> Full step-by-step instructions: `Documentation/Windows-Smoke-Run.md`