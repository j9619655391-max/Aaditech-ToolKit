# Create-ElevatedTask.ps1 - register the on-demand elevated helper task.
#
# E4: the routine ITToolkitAgent task runs as NETWORK SERVICE (least privilege).
# Admin-required work (MSI self-upgrade, reboot, elevated-only collectors) is
# staged by the agent as elevated-job.json and this task is triggered via
# `schtasks /run`. It runs once (-ElevatedOnce) as SYSTEM/Highest.
#
# The tricky part is that `schtasks /run` needs task-run permission. A task
# created with plain schtasks is only runnable by SYSTEM/Administrators — not by
# NETWORK SERVICE. So we register it through the Task Scheduler COM API and give
# NT AUTHORITY\NETWORK SERVICE the run (0x2) right in the security descriptor.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AgentExe
)

$name   = 'ITToolkitAgentElevated'
$taskLog = Join-Path $env:SystemRoot 'Temp\ITToolkit-Agent-elevated.log'

# DACL: NETWORK SERVICE + SYSTEM get read/execute (0x1200a9) so the routine
# (unprivileged) agent can trigger via `schtasks /run`; SYSTEM full control
# (0x1f01bf) + Administrators full control. No triggers -> only manual run.
$sd = 'D:(A;;0x1200a9;;;S-1-5-20)(A;;0x1200a9;;;S-1-5-18)(A;;0x1f01bf;;;S-1-5-18)(A;;0x1f01bf;;;S-1-5-32-544)'

try {
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $root = $service.GetFolder('\')
    $task  = $service.NewTask(0)   # no flags

    $task.RegistrationInfo.Description = 'IT-Toolkit Agent - on-demand elevated helper (E4)'
    $task.RegistrationInfo.Author      = 'IT-Toolkit'

    $task.Principal.UserId    = 'SYSTEM'
    $task.Principal.LoginType = 5     # TASK_LOGON_SERVICE_ACCOUNT
    $task.Principal.RunLevel  = 1     # TASK_RUNLEVEL_HIGHEST

    $task.Settings.Enabled                       = $true
    $task.Settings.Hidden                        = $true
    $task.Settings.DisallowStartIfOnBatteries    = $false
    $task.Settings.StopIfGoingOnBatteries        = $false
    $task.Settings.ExecutionTimeLimit            = 'PT8H0M0S'
    $task.Settings.DeleteExpiredTaskAfter        = 'PT1H'
    $task.Settings.OneTimeNonGamePlayedTaskReset = $false

    # Execute IT-Toolkit-Agent.exe -ElevatedOnce (no triggers -> no self-start)
    $action = $task.Actions.Create(0)            # TASK_ACTION_EXEC
    $action.Path      = $AgentExe
    $action.Arguments = '-ElevatedOnce'
    $action.ID        = "Run$name"

    # Flags: 6 = TASK_CREATE_OR_UPDATE. We pass the SDDL so the LOW-PRIVILEGE
    # routine agent (NETWORK SERVICE) can trigger this via `schtasks /run`.
    $null = $root.RegisterTask($name, $task, 6, 'SYSTEM', $null, 5, $sd)
    Add-Content $taskLog "Registered $name at $(Get-Date)" -ErrorAction SilentlyContinue
    Write-Output "Registered $name (elevated on-demand task)"
}
catch {
    Add-Content $taskLog "ERROR: $($_.Exception.Message)" -ErrorAction SilentlyContinue
    Write-Output "WARN: could not register elevated task: $($_.Exception.Message)"
    exit 1
}