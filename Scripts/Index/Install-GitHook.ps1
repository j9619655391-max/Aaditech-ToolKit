# Install-GitHook.ps1 - Install the auto-index pre-commit hook into .git/hooks
# Run from anywhere in the repo:  pwsh -NoProfile -File Scripts/Index/Install-GitHook.ps1

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$hookSource = Join-Path $repoRoot '.githooks/pre-commit'
$gitHooksDir = Join-Path $repoRoot '.git/hooks'
$hookDest = Join-Path $gitHooksDir 'pre-commit'

if (-not (Test-Path $repoRoot/.git)) {
    Write-Host "No .git directory found at $repoRoot - not a git repository." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $hookSource)) {
    Write-Host "Hook source missing: $hookSource" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $gitHooksDir -Force | Out-Null

# Use a symlink so the hook stays in sync with the committed copy (where supported).
$existing = if (Test-Path $hookDest) { Get-Item $hookDest } else { $null }
if ($existing) {
    if ($existing.LinkType) {
        Remove-Item $hookDest -Force
    } else {
        Remove-Item $hookDest -Force
    }
}

$symlinkOk = $true
try {
    New-Item -ItemType SymbolicLink -Path $hookDest -Target $hookSource -ErrorAction Stop | Out-Null
} catch {
    $symlinkOk = $false
}

if (-not $symlinkOk) {
    Copy-Item $hookSource $hookDest -Force
    # Make executable
    & chmod +x $hookDest 2>$null
    Write-Host "Copied hook (symlink not supported): $hookDest"
} else {
    Write-Host "Installed hook symlink: $hookDest -> $hookSource"
}

Write-Host "Auto-index pre-commit hook installed. Every commit will refresh project-index.json, project-state.json, project-progress.json."
