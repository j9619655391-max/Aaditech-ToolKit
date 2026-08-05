<#
.SYNOPSIS
    Pins commonly-needed folders to File Explorer's Quick Access so you never
    have to browse for them again on a machine you're supporting.
.NOTE
    Edit the $folders list to match paths that exist on the machine you're on
    (some, like Downloads, exist on every machine; network paths will vary).
#>

$shell = New-Object -ComObject Shell.Application

$folders = @(
    "$env:USERPROFILE\Downloads",
    "$env:SystemRoot\System32\LogFiles",
    "$env:SystemRoot\Temp",
    "C:\Users",
    "$env:SystemDrive\Windows\System32\drivers"
    # Add network paths here if applicable, e.g.:
    # "\\fileserver\IT-Share"
)

foreach ($folder in $folders) {
    if (Test-Path $folder) {
        try {
            $shell.Namespace($folder).Self.InvokeVerb("pintohome")
            Write-Host "Pinned: $folder" -ForegroundColor Green
        } catch {
            Write-Host "Could not pin: $folder (verb may not be available on this Windows build)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Skipped (not found): $folder" -ForegroundColor DarkYellow
    }
}

Write-Host "`nDone. Check File Explorer > Quick Access." -ForegroundColor Cyan
Read-Host "Press Enter to close"
