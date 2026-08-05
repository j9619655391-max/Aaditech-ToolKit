# Troubleshooting Flows

Use these as a fixed sequence — don't guess, follow the order.

## 1. No Internet / Network Issue

```
Start
  |
  v
Is IP assigned? (ipconfig) --No--> Check cable/Wi-Fi driver, renew IP (ipconfig /renew)
  |
 Yes
  |
  v
Can you ping the Gateway? --No--> Check switch/router/cable, restart adapter
  |
 Yes
  |
  v
Does DNS resolve (nslookup google.com)? --No--> Change DNS to 8.8.8.8, flush DNS
  |
 Yes
  |
  v
Can you ping 8.8.8.8 (internet)? --No--> Check firewall, ISP/router, contact ISP
  |
 Yes
  |
  v
Resolved — issue is likely app-specific (proxy, browser, or firewall rule)
```
Tip: run `Scripts\Network-Diagnostic.ps1` to automate this exact sequence.

## 2. PC Running Slow

```
Start
  |
  v
Check Task Manager: CPU/RAM/Disk maxed? --Yes--> Identify top process, close/restart it
  |
  No
  v
Check free disk space < 15%? --Yes--> Clean temp files, empty recycle bin, WinDirStat
  |
  No
  v
Check Startup apps (too many)? --Yes--> Disable non-essential startup items
  |
  No
  v
Check Windows Update pending restart? --Yes--> Restart and complete updates
  |
  No
  v
Check disk health (SMART)? --Fail--> Back up data immediately, plan disk replacement
  |
  Pass
  v
Run sfc /scannow + DISM RestoreHealth
```

## 3. Printer Not Working

```
Start
  |
  v
Is Print Spooler service running? --No--> net start spooler
  |
 Yes
  |
  v
Are there stuck jobs in queue? --Yes--> Clear C:\Windows\System32\spool\PRINTERS, restart spooler
  |
  No
  |
  v
Is printer reachable on network (ping printer IP)? --No--> Check printer network/power
  |
 Yes
  |
  v
Reinstall/update printer driver
```

## 4. Login / Account Issue

```
Start
  |
  v
Is account locked in AD? --Yes--> Unlock account, check lockout policy/reason
  |
  No
  |
  v
Is machine connected to domain network/VPN? --No--> Connect to VPN/network first
  |
 Yes
  |
  v
Check time sync (Kerberos fails if clock is off) --Bad--> Sync time with domain controller
  |
  Good
  v
Recreate local user profile cache if corrupted
```

## 5. VPN Not Connecting

```
Start
  |
  v
Are credentials correct/not expired? --No--> Reset password, re-enter credentials
  |
 Yes
  |
  v
Is DNS resolving VPN gateway address? --No--> Flush DNS, try alternate DNS
  |
 Yes
  |
  v
Is VPN client up to date? --No--> Update/reinstall VPN client
  |
 Yes
  |
  v
Check firewall/antivirus blocking VPN ports
```

---
*Part of the IT Toolkit — see Setup-Guide.md for full instructions.*
