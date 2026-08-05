# IT Toolkit v2.0 — Documentation Audit

**Date:** 2026-08-05
**Method:** Every documentation claim cross-checked against actual code. Flagging all mismatches (RULE #14).

---

## Documentation inventory

| File | Lines | Role |
|---|---|---|
| `Documentation/README.md` | 377 | Master index |
| `Documentation/Setup-Guide.md` | 121 | First-time setup |
| `Documentation/Cheat-Sheet.md` | 62 | Quick reference |
| `Documentation/Troubleshooting-Flowcharts.md` | 136 | Decision trees |
| `Scripts/README.md` | 438 | Script reference |
| `Remote-Tools/README.md` | 23 | Remote tools |
| `Software/Portable-Software-Links.md` | 31 | Download links |
| `Scripts/Remote/README.md` | 27 | Remote ops |
| `Scripts/Tests/README.md` | 23 | Test instructions |
| `CHANGELOG.md` | 85 | Version history |
| `COMPLETION-REPORT.md` | 540 | Completion claims |
| `QUICK-SUMMARY.md` | 277 | Executive summary |
| `IT-TOOLKIT-GAP-ANALYSIS.md` | 303 | Gap analysis |
| `ANALYSIS-RECOMMENDATIONS.md` | 1361 | Roadmap |
| `Scalling Plan/*.md` (9 files) | 5891 total | Implementation planning docs |

**Total Markdown files:** 23 | **Total LOC (md):** ~9,000

---

## Confirmed documentation mismatches (RULE #14)

### DOC-001 — Claim "All Phase 1 regression tests passed" is FALSE
- **Claimed in:** `Scripts/README.md:38`, `COMPLETION-REPORT.md`, `audit/ledger.json:150,167`, `Scalling Plan/DELIVERY-SUMMARY.md`
- **Actual:** Running `Scripts/Tests/Phase1-Regression.Tests.ps1` produces **3 failures** (CSV header x2, Alert severity). See `testing.md`.
- **Impact:** Maintainers and users believe the suite is green; it is red.
- **Suggested fix:** Fix the test assertions (CSV regex + severity expectation), or fix the module defaults; re-run and update docs.
- **Priority:** P0

### DOC-002 — Export-EventLogs claims do not match implementation
- **Claimed in:** `Scripts/README.md:123,131-135` ("System, Application, and Security event logs", "Last 7 days", "Up to 500 events per source", "Sanitizable format")
- **Actual:** `Export-EventLogs.ps1:19` iterates only `@("System", "Application")` — **Security is NOT exported**. The hours prompt defaults to 24, not 7 days. No `eventLogSettings` config is read. No sanitization logic exists in the script (the README says output is "sanitizable" and instructs manual sanitizing).
- **Suggested fix:** Update the script to honor `config.json` `eventLogSettings` (sources/days/max), or correct the README.
- **Priority:** P1

### DOC-003 — "50+ pages" documentation claim unverifiable/exaggerated
- **Claimed in:** `Documentation/README.md:372`, `IT-TOOLKIT-GAP-ANALYSIS.md:17`, `QUICK-SUMMARY.md`, `CHANGELOG.md`
- **Actual:** Total markdown content is ~9,000 LOC (~250 printed pages across 23 files). "50+ pages" for the *core* docs (Documentation/ + Scripts/README) is roughly ~700 lines ≈ 20 pages. The claim overstates the maintained documentation package.
- **Priority:** P2 (minor)

### DOC-004 — `Documentation/README.md` references `Saved-RDP-Connections.ps1`
- **Line:** `Remote-Tools/README.md:6`
- **Actual:** The script in the repo is `Remote-Tools/Generate-RDP-Shortcuts.ps1`. `Saved-RDP-Connections.ps1` does not exist.
- **Priority:** P2

### DOC-005 — Setup-Guide claims menu "option 8 (Ticket Reply Templates)"
- **Line:** `Documentation/Setup-Guide.md:70`
- **Actual:** `Toolkit-Menu.bat` shows `10. Open Ticket Reply Templates` (option 10), not 8. Also options 7-14 numbering in Setup-Guide differ from the menu. Menu mappings are inconsistent with docs.
- **Priority:** P2

### DOC-006 — `CHANGELOG.md` claims "No incomplete features" / "QA completed"
- **Lines:** `CHANGELOG.md:56-64`
- **Actual:** `RemoteToolkit.psm1` is non-importable, `CredentialManager.psm1` is a stub, `Toolkit-Menu.bat` cannot read input, and the regression suite fails. Claims contradict verified state.
- **Priority:** P0

### DOC-007 — `Scalling Plan/ARCHITECTURE.md` describes files that do not exist
- e.g., `Data/Schema.sql`, `Data/ToolkitData.sqlite`, `Integration/`, `GUI/`, `Remediation/`, `Compliance/` — all listed as Phase 2/3 structure. These are **plans**, not present files. The doc does label them as future phases, but its "CURRENT STRUCTURE (v2.0)" section lists `Scripts/Tests/` and module files that exist. Flagged as forward-looking but partially aspirational.
- **Priority:** P2

---

## Documentation positives

- `Scripts/README.md` is genuinely comprehensive and mostly accurate on script purpose.
- `Troubleshooting-Flowcharts.md` provides useful decision trees.
- `Templates/AI-Assistant-Prompts.txt` sanitization guidance is exemplary.
- Setup documentation (`Setup-Guide.md`) is practical and correct in spirit.

## Metrics (computed)

| Metric | Value |
|---|---|
| Documentation files | 23 |
| Docs with verified claims | ~12 |
| Docs with at least one mismatch | ~7 (DOC-001..007) |
| ADR / architecture decision records | 0 |
| Sequence/flow diagrams | ASCII flowcharts in Troubleshooting-Flowcharts.md |
| API docs | N/A (no API) |
| Deployment docs | Partial (Setup-Guide) |
| Documentation accuracy score | ~60% (weighted by criticality of DOC-001/006) |

## Verdict

**NOT ACCURATE ENOUGH FOR RELEASE.** Two claims are materially false (tests pass; QA complete). Documentation must be corrected to reflect the actual broken state before any release claim is made.
