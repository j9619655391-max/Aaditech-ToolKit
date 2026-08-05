# Remote Operations for IT Toolkit

## Overview
This folder contains Phase 2 remote execution scripts that allow the toolkit to run diagnostics on remote machines.

## Scripts
- `Invoke-RemoteQuickCheck.ps1`: Run the QuickCheck script on a single remote machine.
- `BatchScan.ps1`: Run a parallel scan across multiple remote machines.
- `Invoke-RemoteNetworkDiagnostic.ps1`: Run the network diagnostic script on a remote machine.

## Requirements
- `Scripts/Modules/RemoteToolkit.psm1`
- `Scripts/Modules/CredentialManager.psm1`
- `Config/config.json` remoteExecution section configured
- WinRM enabled on target Windows machines

## How to use
1. Add remote machine entries to `Config/config.json`.
2. Configure remote execution settings in `remoteExecution`.
3. Run one of the scripts:
   - `PowerShell -ExecutionPolicy Bypass -File Scripts\Remote\Invoke-RemoteQuickCheck.ps1`
   - `PowerShell -ExecutionPolicy Bypass -File Scripts\Remote\Invoke-RemoteNetworkDiagnostic.ps1`
   - `PowerShell -ExecutionPolicy Bypass -File Scripts\Remote\BatchScan.ps1 -ComputerNames Server01,Server02`

## Notes
- `BatchScan.ps1` uses parallel jobs and may be limited by system resources.
- Credential storage and retrieval are handled by `CredentialManager.psm1`.
