# IT Toolkit — Setup Guide (Start Here)

A plug-and-play personal toolkit for Desktop Support / IT Infrastructure work.
No installation, no admin approval needed for 90% of it. Just copy the folder to
a USB drive or a shared folder you have access to on every machine you touch.

## 1. Folder Structure (already built for you)

```
IT-Toolkit/
├── Toolkit-Menu.bat            <- MASTER LAUNCHER - double-click this first, every time
├── CHANGELOG.md                <- What's in this version
├── Scripts/
│   ├── Run-QuickCheck.bat      <- Standalone launcher for QuickCheck.ps1 (also reachable from master menu)
│   ├── QuickCheck.ps1          <- 13-option diagnostics menu
│   ├── Network-Diagnostic.ps1  <- Automated step-by-step network test
│   ├── Printer-Fix.ps1         <- Restarts spooler, clears stuck jobs (run as Admin)
│   ├── Export-EventLogs.ps1    <- Exports sanitizable event log excerpts for tickets
│   └── Pin-QuickAccess-Folders.ps1  <- Pins common folders to File Explorer Quick Access
├── Templates/
│   ├── Ticket-Reply-Templates.txt   <- Copy/paste email replies
│   ├── Knowledge-Base.xlsx          <- Your searchable fix history (3 tabs)
│   ├── CMD-Commands-Reference.txt  <- Every common CMD command, copy-paste ready
│   └── AI-Assistant-Prompts.txt     <- Ready-to-use prompts for pasting into an AI chat tool
├── Remote-Tools/
│   ├── README.md                    <- Built-in + approved third-party remote options
│   └── Generate-RDP-Shortcuts.ps1   <- Creates one-click .rdp files for machines you support
├── Documentation/
│   ├── Setup-Guide.md          <- This file
│   ├── Cheat-Sheet.md          <- One-page printable reference
│   └── Troubleshooting-Flowcharts.md  <- Fixed step-by-step decision trees
├── Drivers/     <- Empty on purpose - drop driver packages here as you collect them
├── Software/
│   └── Portable-Software-Links.md   <- Official download links for every portable tool (PowerToys, Sysinternals, etc.)
└── Logs/        <- Auto-fills when you run Full Health Check or Export Event Logs
```

## 2. First-Time Setup (5 minutes)

1. Copy the entire `IT-Toolkit` folder to a USB drive or a synced shared folder
   (OneDrive/network share) so it's the same on every PC you use.
2. Double-click `Toolkit-Menu.bat` at the root of the folder → if Windows SmartScreen warns you,
   click "More Info" → "Run Anyway" (this is normal for unsigned scripts you wrote yourself).
3. Confirm it opens the menu. If PowerShell blocks it with an execution policy error, run this
   **once** in an elevated PowerShell window:
   ```
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```
4. Open `Templates\Knowledge-Base.xlsx` and bookmark it — this is the single highest-value
   habit in this whole toolkit (see Section 5).

## 3. Daily Use

Start every session with **`Toolkit-Menu.bat`** at the root of the folder — it's the front
door to everything else below, so you never have to remember which subfolder a tool lives in.

- **New ticket comes in** → Master Menu → option 1 (QuickCheck) → pick System Info, Disk Space,
  Services, etc. instead of typing commands from memory.
- **"No internet" ticket** → Master Menu → option 2 (Network Diagnostic). Walks IP → Gateway →
  DNS → Internet → Firewall in order and prints PASS/FAIL for each step so you instantly know
  where the break is.
- **Printer issue** → Master Menu → option 3 (Printer Fix). Restarts the spooler, clears stuck
  jobs, and lists installed printers with status. Requires admin (it'll prompt automatically).
- **"System is slow" ticket** → QuickCheck → option 12 (Full Health Check). Saves a timestamped
  report into `Logs/` and opens it in Notepad automatically.
- **Need logs for an escalation/vendor ticket** → Master Menu → option 4 (Export Event Logs).
  Saves recent errors/warnings to a text file you can attach directly.
- **New machine you'll support regularly** → Master Menu → option 5 (Pin Quick Access) and
  option 6 (Generate RDP Shortcuts) to set it up for fast future access.
- **Replying to users** → Master Menu → option 8 (Ticket Reply Templates), copy the matching
  template, fill in the brackets, paste into your ticketing tool or email.
- **Stuck on something unfamiliar** → Master Menu → option 10 (AI Assistant Prompts) for
  ready-made prompts to paste into your AI chat tool — remember to sanitize identifying info first.
- **After solving anything new or unusual** → add one row to `Knowledge-Base.xlsx` (Tab 1).
  Takes 30 seconds, saves you re-searching the same problem in 6 months.

## 4. Populating Drivers / Software Folders (one-time, ongoing)

Open `Software/Portable-Software-Links.md` — it has verified official download links for
every portable tool (Sysinternals Suite, PowerToys, Notepad++, WinDirStat, 7-Zip, PuTTY,
Advanced IP Scanner, CrystalDiskInfo, HWiNFO, CPU-Z). Download once, extract into `Software/`,
and you'll never need to re-download on the road.

Add manufacturer driver packages to `Drivers/` organized by brand
(Intel, Realtek, NVIDIA/AMD, Dell, HP, Lenovo, Brother, Canon, Epson) — this saves you
re-downloading the same driver every time you image a machine.

## 5. The One Habit That Compounds (Knowledge Base)

Every time you solve something you haven't seen before (or haven't seen in a while):

| Column | What to enter |
|---|---|
| Date | Today's date |
| Category | Network / Printer / Windows / Login / VPN etc. |
| Problem | What the user reported, in plain words |
| Root Cause | What was actually wrong |
| Solution / Commands Used | Exact commands or steps that fixed it |
| Time Saved (min) | Rough estimate — this adds up and is great for performance reviews |

After 6-12 months this becomes faster to search than Google, because it's *your* fixes,
in *your* environment, with *your* exact commands already tested.

## 6. Security Notes

- Do **not** store real passwords in Clipboard History (Win+V) or in the Knowledge Base —
  use a proper password manager (e.g., KeePass, Bitwarden) for any credentials.
- Sanitize hostnames, IP addresses, and usernames before pasting logs into any public AI
  chat tool if your company has a data-handling policy — replace with generic placeholders.
- `chkdsk /f` and DISM repair commands should be run with awareness that they may require
  a restart — don't run them on a user's machine without a heads-up.

## 7. Extending This Toolkit

- Add more menu options to `QuickCheck.ps1` any time you find yourself typing the same
  command more than twice — that's the signal it belongs in the toolkit.
- Add more tabs to `Knowledge-Base.xlsx` if you want to track specific asset types
  (e.g., a Laptop Inventory tab, a Software License tab).

---
You're fully set up. Start with `Scripts\Run-QuickCheck.bat` on your next ticket.
