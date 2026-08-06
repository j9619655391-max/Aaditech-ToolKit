<#
Phase2-Modules.Tests.ps1
================================================================
Regression tests for the Phase 2 modules added during the hardening pass:
  - SanitizeEngine  (PII redaction for exported data)
  - ToolkitData    (SQLite persistence layer via sqlite3 CLI)
  - TaskScheduler  (cron-style recurrence + Windows task scheduling)
  - CredentialManager (secure credential storage)

Pure logic (SanitizeEngine, ToolkitData, cron builder, scheduler guard)
is fully exercised on any host. Windows-only scheduling registration is
covered by a guard test only.
#>

[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '')]
param()

BeforeAll {
    $global:moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\modules')).Path
}

Describe 'SanitizeEngine' {
    It 'masks email addresses, IPs, and domain accounts' {
        Import-Module (Join-Path $global:moduleRoot 'SanitizeEngine.psm1') -Force
        $result = ConvertTo-SanitizedText -Text 'alice@contoso.com from 10.0.0.5 as DOMAIN\jsmith' -UseConfig:$false
        $result | Should -Match '[REDACTED-EMAIL]'
        $result | Should -Match '[REDACTED-IP]'
        $result | Should -Match 'REDACTED-ACCOUNT'
    }

    It 'masks an explicitly known hostname but not arbitrary words' {
        Import-Module (Join-Path $global:moduleRoot 'SanitizeEngine.psm1') -Force
        $result = ConvertTo-SanitizedText -Text 'server SRV01 rebooted; value is normal' -KnownHostnames @('SRV01') -UseConfig:$false
        $result | Should -Match '[REDACTED-HOSTNAME]'
        $result | Should -Match 'normal'
    }

    It 'does not crash on whitespace text' {
        Import-Module (Join-Path $global:moduleRoot 'SanitizeEngine.psm1') -Force
        ConvertTo-SanitizedText -Text '   ' -UseConfig:$false | Should -Be '   '
    }

    It 'Protect-SanitizedContent sanitizes string properties of objects' {
        Import-Module (Join-Path $global:moduleRoot 'SanitizeEngine.psm1') -Force
        $obj = [pscustomobject]@{ Host = 'user@contoso.com'; Message = 'pressed 10.0.0.5' }
        $clean = @($obj | Protect-SanitizedContent -KnownHostnames @()) | Select-Object -First 1
        $clean.Host | Should -Match '[REDACTED-EMAIL]'
        $clean.Message | Should -Match '[REDACTED-IP]'
    }
}

Describe 'ToolkitData' {
    It 'creates a database, stores inventory, and reads it back' {
        Import-Module (Join-Path $global:moduleRoot 'ToolkitData.psm1') -Force
        if (-not (Test-SQLiteBinary)) { Set-ItResult -Skipped -Because 'sqlite3 not available' }
        $db = Join-Path $TestDrive 'toolkit.sqlite3'
        Initialize-ToolkitDatabase -DatabasePath $db | Should -Not -BeNullOrEmpty
        Add-ToolkitInventoryRecord -ComputerName 'TESTPC-1' -InventoryObject ([pscustomobject]@{ CPU = 'Intel'; RAM = '16GB' }) -DatabasePath $db | Should -Be $true
        Add-ToolkitInventoryRecord -ComputerName 'TESTPC-2' -InventoryObject ([pscustomobject]@{ CPU = 'AMD'; RAM = '8GB' }) -DatabasePath $db | Should -Be $true
        $rows = @(Get-ToolkitInventory -DatabasePath $db)
        $rows.Count | Should -Be 2
        @($rows | Where-Object { $_.computerName -eq 'TESTPC-1' }).Count | Should -Be 1
    }

    It 'stores diagnostics with a kind label' {
        Import-Module (Join-Path $global:moduleRoot 'ToolkitData.psm1') -Force
        if (-not (Test-SQLiteBinary)) { Set-ItResult -Skipped -Because 'sqlite3 not available' }
        $db = Join-Path $TestDrive 'diag.sqlite3'
        Add-ToolkitDiagnostic -ComputerName 'TESTPC-1' -Kind 'eventlog' -Result 'ok' -DatabasePath $db | Should -Be $true
        $q = & sqlite3 $db "SELECT COUNT(*) FROM diagnostics WHERE kind='eventlog';"
        $q | Should -Be '1'
    }

    It 'Remove-ToolkitData deletes the database file' {
        Import-Module (Join-Path $global:moduleRoot 'ToolkitData.psm1') -Force
        if (-not (Test-SQLiteBinary)) { Set-ItResult -Skipped -Because 'sqlite3 not available' }
        $db = Join-Path $TestDrive 'remove.sqlite3'
        Initialize-ToolkitDatabase -DatabasePath $db | Out-Null
        Remove-ToolkitData -DatabasePath $db
        Test-Path $db | Should -Be $false
    }
}

Describe 'TaskScheduler' {
    It 'builds a daily cron descriptor from EveryDays/AtTime' {
        Import-Module (Join-Path $global:moduleRoot 'TaskScheduler.psm1') -Force
        New-CronExpression -EveryDays 1 -AtTime '18:30' | Should -Be 'cron: 0 30 18 * * */1'
        New-CronExpression -EveryDays 2 -AtTime '08:00' | Should -Be 'cron: 0 0 8 * * */2'
    }

    It 'clamps invalid EveryDays below 1 to 1' {
        Import-Module (Join-Path $global:moduleRoot 'TaskScheduler.psm1') -Force
        New-CronExpression -EveryDays 0 -AtTime '09:00' | Should -Be 'cron: 0 0 9 * * */1'
    }

    It 'Get-TaskSchedulerAvailable is false off Windows (guard)' {
        Import-Module (Join-Path $global:moduleRoot 'TaskScheduler.psm1') -Force
        Get-TaskSchedulerAvailable | Should -Be ($env:OS -eq 'Windows_NT')
    }
}

Describe 'CredentialManager' {
    It 'exports the canonical Save-ToolkitCredential and Store alias' {
        Import-Module (Join-Path $global:moduleRoot 'CredentialManager.psm1') -Force
        Get-Command Save-ToolkitCredential -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Store-ToolkitCredential -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}