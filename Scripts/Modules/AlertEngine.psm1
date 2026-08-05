# AlertEngine.psm1 - Threshold-based alerting system
# Part of IT Toolkit v2.0 Enhancement - Phase 1

<#
.SYNOPSIS
    Provides threshold-based alerting for system metrics.

.DESCRIPTION
    This module provides functions to check system metrics against configured
    thresholds and generate alerts with severity levels (Critical, Warning, Info).

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Part of: Phase 1 Implementation
#>

# Get the script directory for path resolution
$script:ModulesPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Test-AlertThreshold {
    <#
    .SYNOPSIS
        Tests a value against a threshold and returns alert information.
    
    .DESCRIPTION
        Evaluates whether a metric value exceeds a threshold and returns
        an alert object with severity level and message.
    
    .PARAMETER Type
        The type of metric (Disk, Memory, CPU, etc.).
    
    .PARAMETER Value
        The current value of the metric.
    
    .PARAMETER Threshold
        The threshold value to compare against.
    
    .PARAMETER SeverityLevels
        Hashtable defining severity levels (optional).
    
    .EXAMPLE
        $alert = Test-AlertThreshold -Type "Disk" -Value 92 -Threshold 85
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Disk", "Memory", "CPU", "Uptime", "Services")]
        [string]$Type,
        
        [Parameter(Mandatory=$true)]
        [double]$Value,
        
        [Parameter(Mandatory=$true)]
        [double]$Threshold,
        
        [Parameter(Mandatory=$false)]
        [Hashtable]$SeverityLevels
    )
    
    # Default severity levels if not provided
    if (-not $SeverityLevels) {
        $SeverityLevels = @{
            Warning  = $Threshold
            Critical = [math]::Min(100, $Threshold + 10)
            Info     = 0
        }
    }
    
    # Determine severity
    $severity = "Info"
    $message = ""
    
    if ($Value -ge $SeverityLevels.Critical) {
        $severity = "Critical"
        $message = "$Type usage is CRITICAL: $Value% (critical threshold: $($SeverityLevels.Critical)%)"
    }
    elseif ($Value -ge $SeverityLevels.Warning) {
        $severity = "Warning"
        $message = "$Type usage is WARNING: $Value% (warning threshold: $($SeverityLevels.Warning)%)"
    }
    else {
        $severity = "Info"
        $message = "$Type usage is normal: $Value%"
    }
    
    # Return alert object
    return [PSCustomObject]@{
        Type         = $Type
        Value        = $Value
        Threshold    = $Threshold
        Severity     = $severity
        Message      = $message
        Timestamp    = Get-Date
        IsAlert      = ($severity -in @("Critical", "Warning"))
    }
}

function Get-AlertSeverity {
    <#
    .SYNOPSIS
        Returns the severity level for a value based on thresholds.
    
    .DESCRIPTION
        Determines if a value is Critical, Warning, or Info based on thresholds.
    
    .PARAMETER Value
        The metric value to evaluate.
    
    .PARAMETER WarningThreshold
        The warning threshold value.
    
    .PARAMETER CriticalThreshold
        The critical threshold value.
    
    .EXAMPLE
        Get-AlertSeverity -Value 85 -WarningThreshold 75 -CriticalThreshold 90
    #>
    param(
        [Parameter(Mandatory=$true)]
        [double]$Value,
        
        [Parameter(Mandatory=$true)]
        [double]$WarningThreshold,
        
        [Parameter(Mandatory=$true)]
        [double]$CriticalThreshold
    )
    
    if ($Value -ge $CriticalThreshold) { return "Critical" }
    elseif ($Value -ge $WarningThreshold) { return "Warning" }
    else { return "Info" }
}

function Format-AlertMessage {
    <#
    .SYNOPSIS
        Formats an alert message with color coding for console output.
    
    .DESCRIPTION
        Takes an alert object and formats it with appropriate colors
        for console display.
    
    .PARAMETER Alert
        The alert object from Test-AlertThreshold.
    
    .EXAMPLE
        $alert = Test-AlertThreshold -Type "Disk" -Value 92 -Threshold 85
        Format-AlertMessage -Alert $alert
    #>
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Alert
    )
    
    switch ($Alert.Severity) {
        "Critical" { $color = "Red" }
        "Warning"  { $color = "Yellow" }
        default    { $color = "Green" }
    }
    
    $message = "$($Alert.Timestamp.ToString('HH:mm:ss')) [$($Alert.Severity)] $($Alert.Message)"
    Write-Host $message -ForegroundColor $color
}

function Test-MultipleThresholds {
    <#
    .SYNOPSIS
        Tests multiple metrics against their thresholds.
    
    .DESCRIPTION
        Takes a hashtable of metrics and their thresholds and returns
        all alerts that exceed thresholds.
    
    .PARAMETER Metrics
        Hashtable of metric names to values.
    
    .PARAMETER Thresholds
        Hashtable of metric names to threshold values.
    
    .EXAMPLE
        $metrics = @{ Disk = 92; Memory = 78; CPU = 45 }
        $thresholds = @{ Disk = 85; Memory = 80; CPU = 90 }
        $alerts = Test-MultipleThresholds -Metrics $metrics -Thresholds $thresholds
    #>
    param(
        [Parameter(Mandatory=$true)]
        [Hashtable]$Metrics,
        
        [Parameter(Mandatory=$true)]
        [Hashtable]$Thresholds
    )
    
    $alerts = @()
    
    foreach ($metricName in $Metrics.Keys) {
        if ($Thresholds.ContainsKey($metricName)) {
            $value = $Metrics[$metricName]
            $threshold = $Thresholds[$metricName]
            
            $alert = Test-AlertThreshold -Type $metricName -Value $value -Threshold $threshold
            if ($alert.IsAlert) {
                $alerts += $alert
            }
        }
    }
    
    return $alerts
}

# Export all functions
Export-ModuleMember -Function Test-AlertThreshold, Get-AlertSeverity, Format-AlertMessage, Test-MultipleThresholds