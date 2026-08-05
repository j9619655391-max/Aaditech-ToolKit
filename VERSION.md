# IT-Toolkit — Version Reference

**Current release:** `v1.0.0`
**Release date:** 2026-08-06
**Branch:** `main`
**Repository identity:** local (no remote configured as of this release)

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

CI (`ci.yml`) runs: PowerShell parse, JSON validation, Phase 1 regression,
PSScriptAnalyzer (errors), and project-index freshness (`-Check`).

## Manual smoke-run items (Windows-only)
The following cannot be end-to-end verified on a macOS dev host and require a
one-time manual smoke run on a Windows machine before deployment:

- Execute `Toolkit-Menu.bat` / `Setup-Wizard.bat` under a real `cmd.exe`
- End-to-end RemoteToolkit (WinRM) against a live target
- Interactive WinForms GUI (`Scripts/GUI/Toolkit-GUI.ps1`)
- Authenticode signing of shipped scripts
- `schtasks.exe` registration via `Register-ToolkitScheduledTask`