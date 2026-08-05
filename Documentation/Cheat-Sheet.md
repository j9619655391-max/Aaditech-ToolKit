# IT Toolkit — One-Page Cheat Sheet

Print this page and keep it at your desk.

## Quick Diagnosis Table

| Problem       | Check First                        | Likely Fix |
|---------------|-------------------------------------|------------|
| No Internet   | IP address, Gateway, DNS            | `ipconfig /flushdns`, reset adapter, or run `Network-Diagnostic.ps1` |
| Outlook Issue | Connectivity, Profile, Cached mode  | Recreate Outlook profile, check Exchange connectivity |
| Printer       | Spooler service, Print queue        | Restart Print Spooler service, clear queue folder |
| Slow PC       | RAM usage, Disk usage, Startup apps | Disable unneeded startup apps, check disk space, run `QuickCheck.ps1` option 12 |
| Login Failure | AD account status, Network path     | Check account lockout in AD, verify domain connectivity |
| VPN           | DNS, Credentials, Client version     | Re-enter credentials, flush DNS, reinstall VPN client |
| Wi-Fi         | Signal strength, Driver version      | Update Wi-Fi driver, forget/rejoin network |
| Blue Screen   | Minidump file, Event Viewer          | Check `C:\Windows\Minidump`, search error code in Event Viewer |

## Most-Used CMD / PowerShell Commands

```
ipconfig /all              View full network config
ipconfig /flushdns         Clear DNS cache
ping <host>                Test connectivity
tracert <host>             Trace network path / find break point
nslookup <host>            Test DNS resolution
gpupdate /force             Force Group Policy update
gpresult /r                 Show applied Group Policy
net use                     List/manage mapped drives
net user <username>         View local user account info
hostname                    Show computer name
whoami                      Show current logged-in user
shutdown /r /t 0             Restart immediately
sfc /scannow                Scan and repair system files
DISM /Online /Cleanup-Image /RestoreHealth   Repair Windows image
chkdsk C: /f                 Check and fix disk errors
```

## Keyboard Shortcuts

| Shortcut         | Action                          |
|------------------|----------------------------------|
| Win + X          | Quick Admin menu                 |
| Win + R          | Run dialog                       |
| Win + E          | File Explorer                    |
| Ctrl + Shift + Esc | Task Manager (direct)           |
| Win + V          | Clipboard history                |
| Alt + Tab        | Switch windows                   |
| Win + Shift + S  | Screenshot / Snipping tool        |
| Win + Ctrl + D   | New virtual desktop               |

## Daily "System Slow" Checklist

1. Task Manager → CPU / Memory / Disk tab
2. Check free disk space (`Get-PSDrive`)
3. Check SMART/disk health status
4. Windows Update status (pending restarts pile up)
5. Event Viewer → any repeated critical errors?
6. Startup apps → disable anything non-essential
7. Confirm free space > 15% of total disk

---
*Part of the IT Toolkit — see Setup-Guide.md for full instructions.*
