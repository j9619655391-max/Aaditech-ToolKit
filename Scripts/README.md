# IT Toolkit - Scripts Reference Guide

Complete documentation for all PowerShell scripts in the toolkit.

---

## 1. QuickCheck.ps1
**What it does:** Multi-option diagnostic menu for system information, disk space, services, running processes

**When to use:**
- Quick health check of a machine
- Verify system specs before/after hardware changes
- Check disk space quickly
- View running services status

**What you'll get:**
- Computer name, OS version, uptime
- Disk space for all drives
- Running services count
- Running processes (top by memory)
- RAM usage
- Network adapters

**How to run:**
```
Option 1: Toolkit-Menu.bat → Choose 1
Option 2: Scripts\Run-QuickCheck.bat (double-click)
Option 3: powershell -ExecutionPolicy Bypass -File Scripts\QuickCheck.ps1
```

**Admin required:** No

**Output:** Console display, with optional report export for Full Health Check

---

## Regression testing for Phase 1
**What it tests:** Export and alert modules, HTML report generation, and log cleanup

**How to run:**
```
PowerShell -ExecutionPolicy Bypass -File Scripts\Tests\Phase1-Regression.Tests.ps1
```

**Output:** Pass/fail summary with non-zero exit code on failures

**Status:** ✅ **All Phase 1 regression tests pass** (verified 2026-08-05, PowerShell 7)

---

## Remote Operations
**What it does:** Run QuickCheck or batch scans on remote machines using WinRM.

**How to run:**
```
PowerShell -ExecutionPolicy Bypass -File Scripts\Remote\Invoke-RemoteQuickCheck.ps1 -ComputerName Server01
PowerShell -ExecutionPolicy Bypass -File Scripts\Remote\Invoke-RemoteNetworkDiagnostic.ps1 -ComputerName Server01
PowerShell -ExecutionPolicy Bypass -File Scripts\Remote\BatchScan.ps1 -ComputerNames Server01,Server02
```

**Notes:**
- Requires `RemoteToolkit.psm1` to be present in `Scripts\Modules`
- Requires `Config\config.json` remoteExecution settings
- Remote machines must be reachable and WinRM enabled

---

## 2. Network-Diagnostic.ps1
**What it does:** Step-by-step network connectivity testing and troubleshooting

**When to use:**
- Internet not working
- Can't reach a specific server
- Network is slow
- Isolate network vs ISP vs DNS issues

**What it tests:**
- DNS resolution
- Gateway connectivity
- Internet connectivity
- Specific host/port connectivity
- Ping response times
- Network adapter status

**How to run:**
```
Toolkit-Menu.bat → Choose 2
```

**Admin required:** No (elevated recommended for advanced tests)

**Output:** Saves report to Logs folder, displays on screen; summary exports are also generated when Phase 1 modules are available

---

## 3. Printer-Fix.ps1
**What it does:** Restarts the print spooler service and clears stuck print jobs

**When to use:**
- Printer won't print anything
- Print queue is stuck with old jobs
- Printer is stuck offline
- "Printer is paused" message

**What it does:**
1. Stops the printer spooler service
2. Deletes stuck print jobs from queue
3. Restarts spooler service
4. Verifies printer is back online

**How to run:**
```
Toolkit-Menu.bat → Choose 3 (launches as Admin automatically)
```

**Admin required:** YES (automatically runs as admin)

**Output:** Success/error messages displayed

**Note:** Clears ALL pending print jobs (expected behavior)

---

## 4. Export-EventLogs.ps1
**What it does:** Exports Windows Event Logs (System, Application, Security) to text files for ticket attachment

**When to use:**
- Attaching error logs to a support ticket
- Troubleshooting system crashes/errors
- Security incident investigation
- Analyzing system warnings

**What it exports:**
- Last 7 days of logs (configurable in config.json)
- System, Application, and Security event logs
- Up to 500 events per source
- Sanitizable format (sensitive info clearly marked)

**How to run:**
```
Toolkit-Menu.bat → Choose 4
```

**Admin required:** No (but elevated for detailed Security logs)

**Output:** Saved to Logs folder as EventExport_[timestamp].txt

**Tip:** Emails, IPs, and domain paths in event messages are auto-masked ([REDACTED-*]); still review for hostnames/usernames before external sharing:

---

## 5. Pin-QuickAccess-Folders.ps1
**What it does:** Automatically pins common folders (Desktop, Documents, Downloads, etc) to File Explorer Quick Access for faster navigation

**When to use:**
- Setting up new user profile
- User keeps forgetting folder locations
- Standardizing user shortcuts across company
- Automating desktop environment setup

**What it pins:**
- Desktop
- Documents
- Downloads
- Network (if applicable)
- OneDrive (if installed)

**How to run:**
```
Toolkit-Menu.bat → Choose 5
```

**Admin required:** No

**Output:** Confirmation messages, updates to File Explorer

---

## 6. User-Inventory.ps1
**What it does:** Generates a comprehensive hardware and software inventory report

**When to use:**
- Asset tracking / audit purposes
- Hardware refresh decisions
- Software license compliance checks
- Documenting machine configuration
- Troubleshooting compatibility issues

**What it collects:**
- OS version, build, install date
- CPU specs (cores, speed)
- RAM amount
- Disk space (all drives)
- BIOS/Firmware version
- Network adapters
- Logged-in users
- Running services count
- Latest Windows updates
- Installed applications (top 30)

**How to run:**
```
Toolkit-Menu.bat → Choose 7
```

**Admin required:** No (some fields require admin for full data)

**Output:** Saved to Logs folder as UserInventory_[timestamp].txt; summary CSV/JSON/HTML exports are also generated when Phase 1 modules are available

**File format:** Plain text, easy to copy/paste or attach to tickets

---

## 7. Firewall-Test.ps1
**What it does:** Tests Windows Firewall status and tests connectivity to common ports

**When to use:**
- Troubleshooting "can't reach server" issues
- Verifying specific ports are open
- Firewall rule testing
- Network connectivity diagnosis
- VPN or RDP access not working

**What it tests:**
- Windows Firewall profile status (Domain/Private/Public)
- Inbound/outbound rules count
- Connectivity to DNS servers
- HTTP (port 80), HTTPS (port 443)
- SSH (port 22), RDP (port 3389)
- Custom ports defined in config.json

**How to run:**
```
Toolkit-Menu.bat → Choose 8
```

**Admin required:** No (but helps with Security log analysis)

**Output:** Saved to Logs folder as FirewallTest_[timestamp].txt; summary CSV/JSON/HTML exports are also generated when Phase 1 modules are available

**Interpret results:**
- ✓ OPEN = port is accessible
- ✗ TIMEOUT = blocked or service not running
- ✗ ERROR = configuration issue

---

## Configuration & Customization

### Editing Script Behavior
All scripts read from **Config\config.json** on startup:

```json
{
  "scriptDefaults": {
    "deleteOldLogsAfterDays": 90,
    "maxLogSize_MB": 100,
    "adminRequired": {
      "PrinterFix": true,
      "UserInventory": false
    }
  }
}
```

### Adding Custom Test Hosts (Firewall-Test)
Edit config.json:
```json
"firewallTest": {
  "customPorts": [
    {
      "name": "Company VPN",
      "host": "vpn.company.com",
      "port": 443,
      "protocol": "TCP"
    }
  ]
}
```

### Phase 1 Reporting and Cleanup
The toolkit now includes Phase 1 export and cleanup support:
- `alertThresholds` for disk, memory, and CPU alert checks
- `logRetention` for automated log cleanup
- `scriptParameters` for tool-specific runtime values
- `Export-ToCSV`, `Export-ToJSON`, and `New-HTMLReport` are available for supported scripts
- Full health checks and diagnostics now save summary exports to the Logs folder

Example config additions:
```json
"alertThresholds": {
  "diskUsagePercent": 85,
  "memoryUsagePercent": 80,
  "cpuUsagePercent": 90,
  "diskFillDays": 7
},
"logRetention": {
  "retentionDays": 90,
  "maxLogsSizeMB": 500,
  "autoCleanup": true
},
"scriptParameters": {
  "networkDiagnosticTimeoutMs": 2000,
  "userInventoryMaxApplications": 50,
  "firewallTestTimeoutMs": 2000
}
```

### Notes
- `QuickCheck.ps1` loads and applies log cleanup automatically at startup.
- Diagnostics scripts export summary data to CSV, JSON, and HTML when the Phase 1 modules are available.

### Customizing Event Log Export
Edit config.json:
```json
"eventLogSettings": {
  "exportSources": ["System", "Application", "Security"],
  "daysToExport": 7,
  "maxEventsPerSource": 500
}
```

---

## Troubleshooting Scripts

### "Execution Policy" Error
If you see: "PowerShell cannot be loaded because running scripts is disabled on this system"

**Fix:**
1. Open PowerShell as Administrator
2. Run: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`
3. Type `Y` to confirm
4. Try script again

### Script Hangs/Freezes
**Common causes:**
- Scanning large number of applications (User-Inventory)
- Waiting for network timeout (Firewall-Test)

**Solution:** 
- Wait 2-3 minutes, or Ctrl+C to cancel
- Adjust timeouts in config.json

### Logs Not Saved
**Check:**
1. Verify Logs folder exists: `Logs/`
2. Check folder permissions (write access required)
3. Verify config.json paths are correct

### "Access Denied" Errors
Some scripts need admin:
- **Printer-Fix:** Always needs admin (auto-elevates)
- **Export-EventLogs:** Needs admin for Security logs
- **User-Inventory:** Works standard, enhanced with admin

**Solution:** Right-click script → "Run as Administrator"

---

## Performance Notes

| Script | Speed | Load |
|--------|-------|------|
| QuickCheck | <5 sec | Very Light |
| Network-Diagnostic | 10-30 sec | Light |
| Printer-Fix | <10 sec | Very Light |
| Export-EventLogs | 5-15 sec | Light |
| Pin-QuickAccess | <5 sec | Minimal |
| User-Inventory | 10-60 sec | Medium (reading app registry) |
| Firewall-Test | 15-45 sec | Light (network timeouts) |

---

## Script Development Notes

### Common Issues to Report
If you find a bug or issue:
1. Run script in PowerShell directly (not batch wrapper)
2. Note exact error message
3. Check Event Viewer for related errors
4. Include: OS version, error code, what you were doing

### Extending Scripts
All scripts are designed to be modified:
- Well-commented code
- Configurable via config.json
- Modular functions
- Standard PowerShell practices

---

## Version History

**v2.0 (2026-07)**
- Complete Firewall-Test.ps1 (was incomplete)
- Enhanced User-Inventory with more details (BIOS, updates, better formatting)
- Added config-driven customization
- All scripts now read config.json
- Improved error handling
- Better colored output and formatting

**v1.0 (2026-06)**
- Initial release
- Core scripts implemented

---

## Tips & Best Practices

✅ **DO:**
- Run scripts as admin for best results
- Save important logs for audit trails
- Check config.json for custom settings
- Use Toolkit-Menu.bat as your launch point
- Review logs after running scripts

❌ **DON'T:**
- Modify script paths without updating config.json
- Delete Logs folder during operation
- Run conflicting scripts simultaneously
- Edit scripts without backup
- Run unknown scripts from untrusted sources

---

## Support & Documentation

- **Setup Guide:** Documentation/Setup-Guide.md
- **Quick Reference:** Documentation/Cheat-Sheet.md
- **Troubleshooting:** Documentation/Troubleshooting-Flowcharts.md
- **Configuration:** Config/config.json (well-commented)
- **AI Prompts:** Templates/AI-Assistant-Prompts.txt (33+ ready-to-use prompts)

---

**Last Updated:** 2026-08-05  
**Toolkit Version:** 2.0  
**Status:** Complete and fully documented
