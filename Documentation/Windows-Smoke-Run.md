# Windows Smoke-Run Manual — IT-Toolkit v1.0.0

> **Purpose:** This runbook lists the checks that **cannot be validated by CI
> on a headless runner** and therefore require a one-time manual execution on a
> real Windows machine before the release is considered fully shipped.
>
> Everything here is **implemented, CI-verified (parse, Pester, PSScriptAnalyzer,
> index freshness — all green), and guarded**, but the actual interactive /
> platform-provided behavior (cmd.exe, WinRM, WinForms, schtasks, Authenticode)
> needs a human on Windows to observe and confirm.

## Prerequisites
- Test device: Windows 10/11 (or Server 2019+), admin PowerShell.
- Copy the toolkit to a local path (no spaces recommended, e.g. `C:\IT-Toolkit`).
- Verify `Execute-Menu` policy is unlocked:
    ```powershell
    Set-ExecutionPolicy -Scope Process RemoteSigned
    ```
- Verify `sqlite3` is reachable (needed by ToolkitData):
    ```powershell
    sqlite3 --version
    ```

---

## 1. Batch launchers under a real cmd.exe

These are the toolkit's "frontend" entry points. Static control-flow is
already covered by `Scripts/Tests/BatchLauncher.Tests.ps1` (9/9 green), but actual
execution is cmd.exe-specific.

- [ ] Run `Toolkit-Menu.bat` from an elevated **Command Prompt
- [ ] Each menu option 1-14 launches the intended script / submenu and returns to the menu
- [ ] Option 7-14 fixed mappings no longer mislaunch (regression from v2.0 fixes)
- [ ] `Setup-Wizard.bat` interactive flows complete (Quick setup, configure, verify, test PS execution)
- [ ] Menu `exit` returns to the shell with no hanging prompts

## 2. RemoteToolkit end-to-end (WinRM)
Covered structurally by `RemoteToolkit.tests.ps1` (5/5). Live execution is WinRM-only.

- [ ] `Test-RemoteConnection` reaches a live target returns `$true`
- [ ] `Invoke-RemoteCommand` runs a command on a live target over WinRM
- [ ] `Invoke-ParallelRemoteExecution` runs across 2+ targets concurrently
- [ ] HTTPS + default credentials path works with config defaults on

---

## 3. Interactive GUI dashboard

`Scripts/GUI/Toolkit-GUI.ps1` is guarded to require Windows (macOS returns exit 2).

- [ ] Launches a WinForms window titled **IT-Toolkit Dashboard**
- [ ] All 8 buttons present; each launches its linked tool
- [ ] "7. Snap inventory to database" writes a row via `ToolkitData`
- [ ] Version footer reads `Version 1.0.0 | Phase 3 dashboard preview`
- [ ] Window closes cleanly on exit

---

## 4. Scheduled tasks (schtasks.exe)

Covered by `TaskScheduler.psm1`; registration is Windows-only.

- [ ] `Register-ToolkitScheduledTask` creates the task (`schtasks /Query /TN ITK-Inventory`)
- [ ] `Get-ToolkitScheduledTask` lists it
- [ ] `Remove-ToolkitScheduledTask` deletes it
- [ ] `New-CronExpression` output is accepted by the task / matches expectation

---

## 5. Credential vault (DPAPI)

Data is local and OS-bound; verify on the target machine.

- [ ] `Save-ToolkitCredential` writes without exposing plaintext
- [ ] `Get-ToolkitCredential` returns without re-prompting after save
- [ ] `Store-ToolkitCredential` alias still works (back-compat)
- [ ] `Remove-ToolkitCredential` deletes the entry

---

## 6. Authenticode signing (release hardening)

CI validates, but only real signing can confirm a trusted install.

- [ ] All `.ps1` / `.psm1` are signed with a trusted code-signing cert
- [ ] `Get-AuthenticodeSignature` reports `Valid` for each shipped file
- [ ] Optional: `Signtool verify /pa` passes on a clean machine

---

## 7. SQLite data layer (ToolkitData)

Covered by `Phase2-Modules.Tests.ps1` on any host with `sqlite3`, but confirm the shipped DB file:

- [ ] `Initialize-ToolkitDatabase` creates `Data/ToolkitData.sqlite3`
- [ ] A diagnostic is stored and `Get-ToolkitInventory` returns it
- [ ] `Data/*.sqlite3*` is git-ignored (not committed)

---

## 8. Final release gate

> Since 2026-08-06 these are **already verified automatically** by GitHub
> Actions CI on `windows-latest` (green). The manual gate below applies only to
> the interactive/live steps (sections 1-7) that CI cannot execute.

- [ ] Run the full Pester suite on Windows (CI already runs these — optional re-check):
    ```powershell
    Invoke-Pester -Path .\Scripts\Tests\RemoteToolkit.tests.ps1   # 5/5
    Invoke-Pester -Path .\Scripts\Tests\BatchLauncher.Tests.ps1   # 9/9
    Invoke-Pester -Path .\Scripts\Tests\Phase2-Modules.Tests.ps1  # 11/11
    ```
- [ ] `pwsh -NoProfile -File .\Scripts\Index\Update-ProjectIndex.ps1 -Check` returns fresh (CI verifies this too)
- [ ] Git worktree clean

---

## When all boxes are checked

1. `v1.0.0` is already tagged and pushed to `origin` (GitHub Actions CI green)
2. Mark the release **fully shipped and platform-verified** in `CHANGELOG.md`

See `../VERSION.md` for the version reference and test inventory.