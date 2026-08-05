# Changelog

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

### 🤖 AUTO-INDEX (added 2026-08-06)
- ✓ `Scripts/Index/Update-ProjectIndex.ps1` — incremental auto-indexer maintaining `project-index.json`, `project-state.json`, `project-progress.json`
- ✓ Detects added/removed/changed files via SHA-256 snapshot deltas; preserves issue/resolution/risk history
- ✓ `Scripts/Index/Install-GitHook.ps1` — installs the pre-commit hook (`.githooks/pre-commit`) so every commit refreshes the index
- ✓ CI now verifies the project index is up to date (`Verify project index is up to date` step)

### ✅ QUALITY ASSURANCE (verified 2026-08-05)
- ✓ Phase 1 regression suite passes (CSV/JSON/HTML export, alert thresholds, log cleanup)
- ✓ RemoteToolkit.psm1 imports and exports all 6 functions
- ✓ Toolkit-Menu.bat reads user input and maps all menu options
- ✓ Firewall-Test.ps1 no longer overwrites the read-only `$host` variable
- ✓ CredentialManager stores/retrieves credentials without exposing plaintext passwords
- ✓ Remote script execution no longer uses `-ExecutionPolicy Bypass`
- ✓ No duplicate files or entries
- ✓ No menu mapping conflicts
- ✓ Configuration consistency verified

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
