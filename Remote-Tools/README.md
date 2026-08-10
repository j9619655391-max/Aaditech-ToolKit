# Remote Tools

This folder is for anything you use to connect to or support a machine remotely.

## Built-in Windows tools (no download needed)
- `mstsc` — Remote Desktop Connection (RDP). Use `Generate-RDP-Shortcuts.ps1` in this folder
  to generate one-click .rdp shortcut files for machines you connect to often.
- `PsExec` (part of Sysinternals Suite, see Software/Portable-Software-Links.md) — run commands
  on a remote machine without installing anything.
- `Enter-PSSession -ComputerName <name>` — remote PowerShell session (needs WinRM enabled).
- Quick Assist (built into Windows 10/11) — screen-share tool, no install, good for end users
  who can't install third-party remote software.

## Third-party (only if your company approves/licenses them)
- TeamViewer QuickSupport — no-install client the *user* runs so you can connect in.
- AnyDesk portable — similar to TeamViewer, lightweight portable version available.

Check your company's remote-access policy before using any third-party remote tool —
many organizations require specific approved software only, for security/audit reasons.

## RDCMan (Sysinternals)
If you regularly RDP into many machines, `RDCMan.exe` (bundled in Sysinternals Suite) lets you
organize all your RDP connections into folders/groups instead of typing hostnames every time.
