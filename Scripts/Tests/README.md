# Phase 1 Regression Tests

This folder contains a standalone PowerShell regression test script for the Phase 1 toolkit enhancements.

## How to run

1. Open PowerShell on Windows.
2. Change directory to the toolkit root:
   ```powershell
   cd 'C:\Path\To\IT-Toolkit 2\Scripts\Tests'
   ```
3. Execute the test script:
   ```powershell
   .\Phase1-Regression.Tests.ps1
   ```

The script validates:
- `ExportEngine` CSV, JSON, and HTML export behavior
- `ReportGenerator` HTML report generation
- `AlertEngine` threshold logic and severity mapping
- `LogManager` retention cleanup for old log files

A non-zero exit code indicates one or more regression failures.
