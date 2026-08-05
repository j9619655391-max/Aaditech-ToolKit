<#
Toolkit-GUI.ps1 - Graphical launcher for IT Toolkit (Phase 3)
================================================================
Windows-only (uses WinForms). Provides a point-and-click dashboard for
the same tools exposed by Toolkit-Menu.bat plus an inventory snapshot
button backed by the SQLite data layer.

Requires: Windows PowerShell 3+ / pwsh on Windows, interactive desktop.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\GUI\Toolkit-GUI.ps1
#>
[CmdletBinding()]
param()

# --- Guard: Windows + interactive desktop required ---
$isWin = ($env:OS -eq 'Windows_NT') -or ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows))
if (-not $isWin) {
    Write-Host 'Toolkit-GUI.ps1 requires Windows WinForms and cannot run on this platform.' -ForegroundColor Yellow
    exit 2
}
if (-not [Environment]::UserInteractive -or [string]::IsNullOrEmpty($env:SESSIONNAME)) {
    Write-Host 'Toolkit-GUI.ps1 must run in an interactive desktop session.' -ForegroundColor Yellow
    exit 2
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'IT Toolkit - Dashboard'
$form.Size = New-Object System.Drawing.Size(460, 420)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$header = New-Object System.Windows.Forms.Label
$header.Text = 'IT TOOLKIT'
$header.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$header.AutoSize = $true
$header.Location = New-Object System.Drawing.Point(20, 15)
$form.Controls.Add($header)

function New-LauncherButton {
    param([string]$Text, [scriptblock]$Action)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Width = 390
    $btn.Height = 34
    $btn.Add_Click($Action)
    return $btn
}

function Start-ToolkitProcess {
    param([string]$FilePath, [switch]$Elevated)
    $args = @('-NoProfile', '-File', $FilePath)
    if ($Elevated) { Start-Process pwsh -Verb RunAs -ArgumentList $args }
    else { Start-Process pwsh -ArgumentList $args }
}

$y = 55
$specs = @(
    @{ Text = '1. QuickCheck (system info)';          File = 'Scripts/QuickCheck.ps1' }
    @{ Text = '2. Network Diagnostic';                File = 'Scripts/Network-Diagnostic.ps1' }
    @{ Text = '3. Printer Fix (elevated)';            File = 'Scripts/Printer-Fix.ps1'; Elevated = $true }
    @{ Text = '4. Export Event Logs';                 File = 'Scripts/Export-EventLogs.ps1' }
    @{ Text = '5. User Inventory';                    File = 'Scripts/User-Inventory.ps1' }
    @{ Text = '6. Firewall Test';                     File = 'Scripts/Firewall-Test.ps1' }
    @{ Text = '8. Open Cheat Sheet';                  File = 'Documentation/Cheat-Sheet.md'; Open = $true }
)

foreach ($spec in $specs) {
    $b = New-LauncherButton -Text $spec.Text -Action {
        param($sender, $e)
        $file = $spec.File
        if ($spec.Open) { Start-Process $file; return }
        if ($spec.Elevated) { Start-ToolkitProcess -FilePath (Join-Path $repoRoot $file) -Elevated; return }
        Start-ToolkitProcess -FilePath (Join-Path $repoRoot $file)
    }
    $b.Location = New-Object System.Drawing.Point(20, $y)
    $form.Controls.Add($b)
    $y += 40
}

$snapshotBtn = New-LauncherButton -Text '7. Snap inventory to database' -Action {
    try {
        Import-Module (Join-Path $repoRoot 'Scripts/Modules/ToolkitData.psm1') -ErrorAction Stop
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = (Get-CimInstance Win32_Processor).Name
        Add-ToolkitInventoryRecord -ComputerName $env:COMPUTERNAME -InventoryObject @{
            OS  = "$($os.Caption) $($os.Version)"
            CPU = $cpu
            RAM = '{0:N1} GB' -f ($os.TotalVisibleMemorySize / 1MB)
        }
        [System.Windows.Forms.MessageBox]::Show('Inventory snapshot saved to data layer.', 'IT Toolkit', 'OK', 'Information')
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed: $_", 'IT Toolkit', 'OK', 'Error')
    }
}
$snapshotBtn.Location = New-Object System.Drawing.Point(20, $y)
$form.Controls.Add($snapshotBtn)
$y += 40

$ver = New-Object System.Windows.Forms.Label
$ver.Text = 'Version 1.0.0  |  Phase 3 dashboard preview'
$ver.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$ver.AutoSize = $true
$ver.ForeColor = [System.Drawing.Color]::Gray
$ver.Location = New-Object System.Drawing.Point(20, ($y + 8))
$form.Controls.Add($ver)

$form.ShowDialog() | Out-Null