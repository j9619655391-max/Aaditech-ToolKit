# IT Toolkit v2.0 — Security Audit

**Date:** 2026-08-05
**Scope:** OWASP ASVS-based review of the complete repository (59 files, 21 PowerShell files)
**Method:** Static analysis + runtime verification via PowerShell 7 (pwsh)

---

## Score Summary

| Area | Verdict | Evidence |
|---|---|---|
| Authentication | N/A (no auth layer) | No login/session system exists |
| Authorization | N/A (no auth layer) | No role/permission system |
| JWT / Sessions / Cookies | N/A | Not present |
| CSRF / CORS | N/A | No web endpoints |
| XSS | LOW RISK (HTML report only) | See CRIT-007 |
| SSRF | N/A | No URL-fetch code |
| SQL Injection | N/A | No database |
| Command Injection | **HIGH RISK** | See SEC-001 |
| Secrets / API Keys | **MEDIUM RISK** | See SEC-002, SEC-004 |
| Passwords | **CRITICAL** | See SEC-003 |
| Environment variables | Low risk | Config uses plain JSON |
| Encryption / TLS | **MEDIUM RISK** | See SEC-005 |
| Headers / Rate limiting / Brute-force | N/A | Local CLI tool |
| File uploads | N/A | No upload functionality |
| Prompt Injection | N/A | AI prompts are static text templates |
| LLM Jailbreak Protection | N/A | No LLM integration |
| Tool Permission Isolation | N/A | Local scripts run with full user/Admin rights |
| Logging hygiene | **MEDIUM RISK** | See SEC-006 |

---

## Confirmed Findings

### SEC-001 — Command Injection / Unvalidated Remote Script Invocation — CRITICAL

- **File:** `Scripts/Modules/RemoteToolkit.psm1:182`, `RemoteToolkit.psm1:215`, `Scripts/Remote/BatchScan.ps1:64`
- **Function:** `Invoke-RemoteNetworkDiagnostic`, `Invoke-QuickCheckRemote`, `Invoke-ParallelRemoteExecution`
- **Evidence:** `& powershell -ExecutionPolicy Bypass -File $networkScript` executes `powershell -ExecutionPolicy Bypass` on remote machines. `$ToolkitRoot` and `$ComputerName` are user-supplied strings from `config.json` or CLI parameters with **no validation**.
- **Reason:** An attacker who can edit `config.json` (shipped as plaintext, world-readable in the repo) or control `-ComputerNames` values can cause arbitrary PowerShell execution on remote hosts with `-ExecutionPolicy Bypass`.
- **Impact:** Full remote code execution on managed fleet machines.
- **Risk:** Critical (exploitable if config is tampered, or via MITM on machine list)
- **Suggested fix:** Validate `$ComputerName` against `[ValidatePattern]` allowlist / DNS allowlist; never use `-ExecutionPolicy Bypass`; use signed scripts and `Set-AuthenticodeSignature`; restrict who may edit `config.json`.
- **Estimated effort:** 4-6 hours
- **Priority:** P0

### SEC-002 — Passwords Exposed via Command Line — CRITICAL

- **File:** `Scripts/Modules/CredentialManager.psm1:32`
- **Function:** `Store-ToolkitCredential`
- **Evidence:** `cmdkey.exe /generic:$TargetName /user:$($Credential.UserName) /pass:$($Credential.GetNetworkCredential().Password)`
- **Reason:** Passing the plaintext password as a command-line argument to `cmdkey.exe` puts the password into the process command line, visible to:
  - Other local processes (process list / `ps`)
  - Windows auditing / command-line history
  - Any script/screen-capture or AV/logging that records process args
- **Impact:** Credential disclosure; violates the OS-level credential hygiene requirement of WinRM/DPAPI.
- **Risk:** Critical
- **Suggested fix:** Use the native `Microsoft.PowerShell.SecretManagement`/SecretStore module, or `cmdkey` with the `/pass` read from a secure prompt is still insecure — instead use `Store-WinRMClientSecret` via DPAPI, or a secured credential file (`Export-Clixml` encrypted by the user's DPAPI key).
- **Estimated effort:** 3-4 hours
- **Priority:** P0

### SEC-003 — Credential Retrieval is a Non-Functioning Stub — HIGH

- **File:** `Scripts/Modules/CredentialManager.psm1:52-56`
- **Function:** `Get-ToolkitCredential`
- **Evidence:** Line 53: `if ($output -match 'Target: $TargetName')` — single-quoted string does **not** interpolate `$TargetName`, so the regex always compares against the literal text `Target: $TargetName` and never matches. Function always returns `$null` (line 56).
- **Reason:** Even if a credential were stored, retrieval is broken. All Phase 2 remote scripts call `Get-ToolkitCredential` (e.g., `BatchScan.ps1:57`) and silently receive `$null`, so remote authentication always fails or falls back to default credentials.
- **Impact:** Remote execution feature cannot authenticate; if fallback occurs, could run without proper credentials.
- **Risk:** High
- **Suggested fix:** Use double quotes (`"Target: $TargetName"`), parse `cmdkey /list` output properly, or switch to SecretManagement.
- **Estimated effort:** 2 hours
- **Priority:** P1

### SEC-004 — Plaintext Sensitive Configuration — MEDIUM

- **File:** `Config/config.json` (security.encryptSensitiveData = `false`), `Scripts/Remote/*`
- **Evidence:** `"security": { "requirePasswordForRDP": true, "encryptSensitiveData": false }`
- **Reason:** Config is plain JSON with no encryption. If real machine names/IPs/credentials are added, they are stored in cleartext. The config's own `notes` claims "Keep a backup".
- **Impact:** Credential & asset-info exposure if the folder is shared/unencrypted.
- **Risk:** Medium
- **Suggested fix:** Enable encryption flag, or move secrets to SecretManagement; document which keys are sensitive.
- **Estimated effort:** 1-2 hours
- **Priority:** P2

### SEC-005 — Remote Transport May Fall Back to Insecure HTTP WinRM — MEDIUM

- **File:** `Scripts/Modules/RemoteToolkit.psm1:38,118`
- **Function:** `Test-RemoteConnection`, `Invoke-ParallelRemoteExecution`
- **Evidence:** `$uri = if ($UseSSL) { "https://..." } else { "http://$ComputerName:$Port/wsman" }` — when `-UseSSL` is not passed, the tool uses **plain HTTP WinRM** (unencrypted). Config default: `"winrmSSL": false`.
- **Reason:** Credentials and session traffic would transit the network unencrypted in default configuration.
- **Impact:** Credential/traffic interception over the network.
- **Risk:** Medium
- **Suggested fix:** Default `winrmSSL` to `true`; require `-UseSSL` for credential-bearing calls; document the risk.
- **Estimated effort:** 2 hours
- **Priority:** P1

### SEC-006 — `LogManager` Deletes Non-Log Files (Documentation) — MEDIUM

- **File:** `Scripts/Modules/LogManager.psm1:56-59`
- **Function:** `Remove-OldLogs`
- **Evidence:** Runtime test deleted `Logs/README.txt` (a doc file) because it matched the "older than N days" rule. `Get-ChildItem -Path $LogsPath -File | Where-Object LastWriteTime -lt $cutoff | Remove-Item` removes **any** old file in the folder, not just logs.
- **Reason:** Deletes legitimate documentation/README files placed in Logs, and could delete user-supplied files if any are placed there.
- **Impact:** Data/documentation loss; no extension filter.
- **Risk:** Medium
- **Suggested fix:** Filter by extension (`.log`, `.txt` report patterns), or move logs to `Logs/reports/` and only clean that subtree.
- **Estimated effort:** 1 hour
- **Priority:** P1

### SEC-007 — No Execution-Policy Hardening / Unsigned Scripts — MEDIUM

- **File:** `Setup-Wizard.bat:52`, `Toolkit-Menu.bat`, `Scripts/Run-QuickCheck.bat:4`
- **Evidence:** Setup-Wizard sets `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`; all launchers call `powershell -ExecutionPolicy Bypass -File ...`. Scripts are unsigned.
- **Reason:** `-ExecutionPolicy Bypass` disables the execution-policy protection for the whole process. Combined with plaintext, unsigned scripts, a modified script in the folder runs without any signature check.
- **Impact:** Tampered toolkit scripts execute without warning.
- **Risk:** Medium
- **Suggested fix:** Sign scripts; keep `-ExecutionPolicy RemoteSigned` (drop `Bypass` where possible); document `Get-AuthenticodeSignature` verification.
- **Estimated effort:** 2-4 hours
- **Priority:** P2

---

## OWASP ASVS Mapping

| ASVS Category | Status |
|---|---|
| V1 Architecture | N/A (no web stack) |
| V2 Authentication | N/A |
| V3 Session Mgmt | N/A |
| V4 Access Control | N/A |
| V5 Validation/Sanitization | FAIL (no input validation on remote hostnames/paths) |
| V6 Stored Crypto | FAIL (plaintext config; cmdkey CLI exposure) |
| V7 Error/Logging | PARTIAL (logs may contain sensitive data; `sanitizeLogs` flag exists but no sanitizer implemented) |
| V8 Data Protection | FAIL (encryptSensitiveData=false) |
| V9 Communication | PARTIAL (HTTP WinRM default) |
| V10 Malicious Code | PARTIAL (scripts unsigned) |
| V11 Business Logic | N/A |
| V12 Files | N/A |
| V13 API/Web | N/A |
| V14 Config | FAIL (no secrets management) |

---

## Verdict

**NOT PRODUCTION-SAFE.** The toolkit is a personal/desktop support tool with two **Critical** security findings (plaintext password on CLI, unvalidated remote command execution with `-ExecutionPolicy Bypass`) and one **High** finding (broken credential retrieval stub). Any multi-machine deployment must first address SEC-001 through SEC-003.
