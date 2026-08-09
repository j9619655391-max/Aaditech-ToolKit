# IT-Toolkit Enterprise — AI-Agent Deployment & Test Runbook

> **Who this is for:** an AI coding agent (or a human giving it instructions)
> driving the deployment + full test of the Enterprise stack on a fresh machine.
>
> **Golden rule:** run the prerequisite scanner FIRST, read its JSON verdict,
> and only then pick a deployment path. Never guess — the scanner is the source
> of truth for "can this host run what we're about to ask of it?"

---

## 0. How an AI agent should use this runbook

1. **Locate the repo** on the target machine (clone it first if needed).
   - Windows: `C:\IT-Toolkit` (no spaces!)
   - macOS/Linux: `~/it-toolkit`
   - `git clone https://github.com/j9619655391-max/Aaditech-ToolKit.git`
2. **Run the scanner** (Step 1 below) → produces `prereq-report.json`.
3. **Parse the JSON**: look at `overall.target`, `overall.decision`, and the
   `checks[]` array. Every `status == "missing"` is a **blocker**; every
   `status == "warn"` is an **advisory**.
4. **Branch** based on `overall.decision`:
   - `run deploy.ps1 ...` → Step 3 (Windows Server, local build)
   - `run deploy.sh ... build_mode=github` → Step 4 (macOS/Linux + GitHub build)
   - `agent-only test box ...` → Step 5 (just install the MSI, no server here)
5. **Follow the target's steps in order.** Each step has a **gate** — a command
   + expected result. Only move to the next step when the gate PASSES.
6. Record every result in the **Test Log** (Step 6). The file
   `Documentation/Windows-Smoke-Run.md` holds the manual Windows checklist that
   CI cannot run; this runbook folds those items into the gate steps.

**Exit codes from the scanner:** `0` = no blockers (go ahead), `1` = at least one
blocker (install the `fix` for each `missing` entry, then re-run).

---

## 1. Step 1 — Prerequisite scan (ALWAYS first)

```powershell
pwsh -NoProfile -File ./Enterprise/tests/Check-Deploy-Prereqs.ps1 -ShowTable -ReportPath ./prereq-report.json
```

Optional target override (auto-detected by default from the OS):

```powershell
pwsh -NoProfile -File ./Enterprise/tests/Check-Deploy-Prereqs.ps1 -ForServerWindows   # force Windows-Server mode
pwsh -NoProfile -File ./Enterprise/tests/Check-Deploy-Prereqs.ps1 -ForServerLinux     # force Linux/macOS mode
pwsh -NoProfile -File ./Enterprise/tests/Check-Deploy-Prereqs.ps1 -ForAgentBox        # agent-only test box
```

**What the scanner checks** (all in one pass):

| ID | What | Blocking for |
| --- | --- | --- |
| `git` | Git CLI present | all targets |
| `python3` | Python 3 present | server-linux (deploy.sh renders config) |
| `openssl` | OpenSSL CLI (cert verify) | server-windows, server-linux |
| `docker` | Docker + compose v2 plugin | server-windows, server-linux |
| `ps2exe` | PowerShell module (agent exe) | server-windows |
| `dotnet` | .NET SDK (WiX ships as a dotnet tool) | server-windows |
| `wix` | WiX v5 toolset | server-windows |
| `signtool` | Windows SDK signtool (warning: unsigned MSI if missing) | server-windows |
| `path-nospace` | repo path has no spaces (warning) | all |
| `execution-policy` | PS execution policy allows running scripts | Windows |
| `admin` | elevated PowerShell (advisory on Windows) | server-windows |
| `ports` | 80 / 443 / 9443 free | server-windows, server-linux |
| `internet` | reach api.github.com | server-windows, server-linux |

> **AI instruction:** if the JSON `overall.blockers > 0`, do NOT start any
> deployment. For each `status == "missing"` check, run its `fix` command,
> then re-run the scanner. Only proceed when the scanner exits `0`.

---

## 2. Step 2 — Parse the verdict & choose the path

Read `overall.decision` from the JSON. The three legal paths:

| Decision contains | Host | Server runs | Agent MSI comes from |
| --- | --- | --- | --- |
| `run deploy.ps1` | Windows Server | on this box (`deploy.ps1`) | built + signed here (local_windows) |
| `run deploy.sh ... github` | macOS/Linux | on this box (`deploy.sh`) | GitHub Actions (build_mode=github) |
| `agent-only test box` | any Windows | **elsewhere** (already deployed) | portal `/api/agent-msi` |

> If you are testing with the **server already running on the Mac** (the current
> dev host) and this box is the **client**, use `-ForAgentBox`.

---

## 3. Step 3 — Windows Server: full bring-up (deploy.ps1)

Gate 3.0 — **docker engine actually works**:
```powershell
docker run --rm hello-world
```
PASS = "Hello from Docker!" → continue. FAIL = fix Docker Desktop/WSL2 first.

Gate 3.1 — **bring up + build** (from the repo root):
```powershell
pwsh -NoProfile -File ./Enterprise/deploy/deploy.ps1
```
PASS = final lines:
```
[deploy] SaaS bring-up complete.
  Portal:       http://<IP>/
  MSI download: http://<IP>/api/agent-msi (after setup, logged in)
```

Gate 3.2 — **health + mTLS cert verifies**:
```powershell
docker compose -f ./Enterprise/docker-compose.yml ps
# CA lives inside the api container (api_data volume) — pull it out to verify
docker compose -f ./Enterprise/docker-compose.yml exec -T api cat /data/certs/ca.crt | Set-Content $env:TEMP\itk-ca.crt -NoNewline
openssl s_client -connect localhost:9443 -CAfile $env:TEMP\itk-ca.crt 2>$null | Select-String "Verify return code: 0"
```
PASS = api container `healthy` AND `Verify return code: 0`.

Gate 3.3 — **MSI was produced + published**:
```powershell
Test-Path ./Enterprise/agent/build/out/IT-Toolkit-Agent.msi
docker compose -f ./Enterprise/docker-compose.yml exec -T api ls /artifacts
```
PASS = MSI exists locally AND shows up in `/artifacts`.

> If `signtool` was a warning, the MSI is unsigned — note it in the test log
> (install still works; SmartScreen will warn).

Then **browser setup** (manual / or drive it via the portal): open `http://<IP>/`,
wizard → company, admin account, SMTP optional, build mode already
`local_windows`. After that: portal login, Agent Setup tab → download
`IT-Toolkit-Agent.msi` + `agent.json` + `ca.crt` + `install-agent.cmd`.

---

## 4. Step 4 — macOS/Linux server + GitHub remote build

Gate 4.0 — **bring up**:
```bash
cd Enterprise/deploy && ./deploy.sh
```
PASS = `[deploy] Server is up` (no `die`). Uses `python3` + `openssl` + `docker`
(same checks the scanner verified).

Gate 4.1 — **health**:
```bash
curl -sf http://localhost/healthz
docker compose -f Enterprise/docker-compose.yml exec -T api python -c "from app.certs import ensure_certs; ensure_certs('localhost')"
```
PASS = `curl` returns 200/JSON with status ok.

Gate 4.2 — **setup wizard with github build mode**:
1. Open `http://<server>/` → wizard.
2. Build mode = **GitHub Actions**, enter `owner/repo` + a fine-grained PAT
   (`Actions: Read/Write`).
3. Complete setup → login as the new admin.

Gate 4.3 — **remote build triggers + MSI comes back** (Agent Setup tab):
- `POST /api/build/validate` → PASS: repo reachable, `actions_write` true.
- `POST /api/build/trigger` → PASS: a `workflow_dispatch` run starts on `main`.
- `GET /api/build/status` → PASS: run goes green, MSI auto-downloads into
  `/artifacts`, `/api/agent-msi` serves it.

---

## 5. Step 5 — Agent test box (install + full client round-trip)

> The stack is already up somewhere (Step 3 or Step 4). This box is a **client**.

Gate 5.0 — **copy the trio next to the MSI**: `IT-Toolkit-Agent.msi`,
`agent.json`, `ca.crt` (from the portal Agent Setup tab).

Gate 5.1 — **install via the one-click cmd (or msiexec)**:
```powershell
# Option A
.\install-agent.cmd
# Option B
msiexec /i IT-Toolkit-Agent.msi /qn /norestart
```
PASS = task exists + agent starts:
```powershell
schtasks /Query /TN ITToolkitAgent
schtasks /Query /TN ITToolkitAgentElevated     # E4: on-demand elevated task
Test-Path "C:\ProgramData\ITToolkit-Agent\queue.sqlite3"
```
- The routine task principal MUST be `NETWORK SERVICE` (E4). If it's `SYSTEM`,
  the install used an old MSI — rebuild.
- **E4 gate:** confirm a standard (non-admin) user CANNOT read
  `agent.json` / `queue.sqlite3`:
  ```powershell
  icacls "C:\ProgramData\ITToolkit-Agent"
  icacls "C:\Program Files\IT-Toolkit\agent.json"
  ```

Gate 5.2 — **first flush → fleet row appears** (portal Fleet page):
PASS = a new agent row with os/ip/agent_version from this box.

Gate 5.3 — **all 7 collectors produce data** (Fleet panels fill in: hardware,
disk/battery, health, updates, bitlocker, licenses admin-only).

Gate 5.4 — **command channel** (portal → Commands → issue):
- `reboot` (delay 0) → PASS: box reboots; result posts back.
- `wake` → PASS: WOL packet logged (needs a peer / BIOS WoL enabled).
- `run-script` → PASS: allowlisted script runs, PII output sanitized.

Gate 5.5 — **MSI upgrade path (A3)**: set a newer target in Agent Setup
(`rollout target`), or rebuild MSI with a bumped `agent-version.json`, install
over → PASS: upgrade succeeds, task recreated, ProgramData retained.

Gate 5.6 — **E4 elevated path**: trigger the on-demand elevated task once:
```powershell
schtasks /Run /TN ITToolkitAgentElevated
Get-Content "C:\Windows\Temp\ITToolkit-Agent-elevated.log"
```
PASS = log shows the elevated run; elevated-only collectors (users/bitlocker/
licenses) produce rows when enabled.

Gate 5.7 — **legacy toolkit smoke** (from `Documentation/Windows-Smoke-Run.md`):
- `Toolkit-Menu.bat` under real cmd.exe, each option launches correctly.
- `RemoteToolkit` WinRM against a second target.
- `Scripts/GUI/Toolkit-GUI.ps1` opens and buttons work.
- Scheduled task `ITK-Inventory` via `TaskScheduler.psm1`; DPAPI credential
  vault round-trip; Authenticode `Get-AuthenticodeSignature` = Valid.

---

## 6. Step 6 — Test log (fill in as you go)

> An AI agent should write each PASS/FAIL/OUTCOME into a markdown table so the
> run is auditable and repeatable.

| Step | Gate | Command run | Result (PASS/FAIL) | Evidence (output/URL) | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | prereq scan | `Check-Deploy-Prereqs.ps1` |  | exit code / blockers= |  |
| 3.1 | bring-up | `deploy.ps1` |  | portal URL |  |
| 3.2 | health+mTLS | openssl s_client |  | Verify return code |  |
| 3.3 | MSI published | ls /artifacts |  | MSI name/size | signed? |
| 4.x | remote build | /api/build/* |  | run id |  |
| 5.1 | install | msiexec / install-agent.cmd |  | schtasks output | NETWORK SERVICE? |
| 5.1 | E4 ACL | icacls |  |  | standard user blocked? |
| 5.2 | fleet row | portal |  | agent row |  |
| 5.3 | collectors | fleet panels |  | kinds received |  |
| 5.4 | commands | reboot/wake/run-script |  | result payloads |  |
| 5.5 | MSI upgrade | rollout target |  | new version row |  |
| 5.6 | elevated task | schtasks /Run |  | elevated log |  |
| 5.7 | legacy smoke | Windows-Smoke-Run.md |  | per-item |  |

**Done = all gates PASS.** Then record the outcome in `CHANGELOG.md`, mark the
release platform-verified, and (if desired) tag it.

---

## Appendix — Common fixes (what the scanner's `fix` fields suggest)

| Problem | Fix |
| --- | --- |
| No Git | `winget install --id Git.Git -e` / `brew install git` |
| No Python 3 | install from python.org (3.10+) |
| No Docker | Docker Desktop (Windows, WSL2 backend) / engine install per OS |
| No ps2exe | `Install-Module ps2exe -Scope CurrentUser -Force` |
| No dotnet | `winget install Microsoft.DotNet.SDK.8` |
| No WiX | `dotnet tool install --global wix --version "5.*"` |
| No signtool | `winget install Microsoft.WindowsSDK` (optional; unsigned otherwise) |
| Ports 80/443/9443 busy | stop the other web server; re-run scan |
| Path has spaces | move repo to `C:\IT-Toolkit` |
| Execution policy | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
