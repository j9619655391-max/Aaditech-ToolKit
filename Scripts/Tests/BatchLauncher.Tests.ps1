<#
BatchLauncher.Tests.ps1
================================================================
Static control-flow validation for the batch launchers.

Because cmd.exe is not available on every dev host, we validate the batch
control-flow structurally:
  - every `goto LABEL` / `goto :LABEL` points at a defined `:LABEL`
  - every numeric menu choice maps to a goto target that exists
  - the batch files are present and non-empty

Skipped (needs a real cmd.exe) is the actual execution; that remains a
documented manual smoke step.
#>

$cases = @()
foreach ($name in @('Toolkit-Menu.bat', 'Setup-Wizard.bat')) {
    $cases += @{ name = $name; file = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) $name) }
}

Describe 'Batch launcher control flow' {
    Context 'File existence' {
        It 'both master batch launchers exist at repo root' {
            $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $missing = foreach ($n in @('Toolkit-Menu.bat', 'Setup-Wizard.bat')) {
                if (-not (Test-Path (Join-Path $root $n))) { return $n }
            }
            $missing | Should -BeNullOrEmpty
        }
    }

    It '<name> is non-empty' -TestCases $cases {
        param($name, $file)
        if (-not (Test-Path $file)) { $file | Should -Exist; return }
        (Get-Content $file).Count | Should -BeGreaterThan 0
    }

    It '<name> defines at least one label' -TestCases $cases {
        param($name, $file)
        if (-not (Test-Path $file)) { $file | Should -Exist; return }
        $labels = foreach ($l in (Get-Content $file)) {
            $t = $l.Trim()
            if ($t -match '^:' -and $t -notmatch '^\s*::') { $t.TrimStart(':') }
        }
        @($labels).Count | Should -BeGreaterThan 0
    }

    It '<name> has no orphan goto targets' -TestCases $cases {
        param($name, $file)
        if (-not (Test-Path $file)) { $file | Should -Exist; return }
        $labels = @(foreach ($l in (Get-Content $file)) {
            $t = $l.Trim()
            if ($t -match '^:' -and $t -notmatch '^\s*::') { $t.TrimStart(':') }
        })
        $gotoTargets = @(foreach ($line in (Get-Content $file)) {
            if ($line.Trim() -match '(?i)^\s*goto\s+(:?\S+)') { ($Matches[1]).Trim().TrimStart(':') }
        })
        $orphans = $gotoTargets | Where-Object { $_ -notin $labels }
        Write-Host "orphaned gotos: [$($orphans -join ',')]"
        $orphans | Should -BeNullOrEmpty
    }

    It '<name> has every menu choice mapped to a defined label' -TestCases $cases {
        param($name, $file)
        if (-not (Test-Path $file)) { $file | Should -Exist; return }
        $labels = @(foreach ($l in (Get-Content $file)) {
            $t = $l.Trim()
            if ($t -match '^:' -and $t -notmatch '^\s*::') { $t.TrimStart(':') }
        })
        $mapOk = $true
        foreach ($line in (Get-Content $file)) {
            $t = $line.Trim()
            if ($t -match '^if\s+"%choice%"\s*==\s*"[^"]+"\s*goto\s+(\S+)') {
                $target = $Matches[1].TrimStart(':')
                if ($target -notin $labels) { Write-Host "choice -> $target (missing label)"; $mapOk = $false }
            }
        }
        $mapOk | Should -Be $true
    }
}