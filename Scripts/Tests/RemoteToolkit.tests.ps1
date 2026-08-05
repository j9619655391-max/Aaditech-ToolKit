<#
RemoteToolkit.tests.ps1

Basic Pester tests for the RemoteToolkit module.
These are lightweight checks that validate module export and basic parameter handling.
#>

Import-Module (Join-Path $PSScriptRoot '..\Modules\RemoteToolkit.psm1') -ErrorAction SilentlyContinue

Describe 'RemoteToolkit Module' {
    Context 'Module exports' {
        It 'Should export Invoke-RemoteCommand' {
            Get-Command Invoke-RemoteCommand -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }

        It 'Should export Invoke-ParallelRemoteExecution' {
            Get-Command Invoke-ParallelRemoteExecution -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }

        It 'Should export Test-RemoteConnection' {
            Get-Command Test-RemoteConnection -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Parameter validation (dry-run)' {
        It 'Invoke-RemoteCommand should throw on missing ComputerName' {
            { Invoke-RemoteCommand -ComputerName $null -ScriptBlock { 1 } -ErrorAction Stop } | Should -Throw
        }

        It 'Test-RemoteConnection should return false for invalid host' {
            $result = Test-RemoteConnection -ComputerName 'invalid-host.example.local' -TimeoutSeconds 3 -ErrorAction SilentlyContinue
            $result | Should -Be $false -Because 'invalid host should not be reachable in CI'
        }
    }
}
