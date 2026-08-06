# Get-LicenseInfo.ps1 - license / product key collector (kind: licenses)
# Enterprise/agent/collectors/ - sensitive: only exposes the LAST 5 of each key
# and never full keys. Default disabled in the feature manifest.

[CmdletBinding()]
$ErrorActionPreference = 'SilentlyContinue'

function ConvertFrom-DigitalProductId {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 68) { return $null }
    $map = 'BCDFGHJKMPQRTVWXY2346789'
    $key = ''
    $offset = 24
    $len = [int]$Bytes[66]
    $last = 0
    for ($i = 28; $i -le 66; $i++) {
        $c = 0
        for ($j = 24; $j -ge 0; $j--) {
            $c = $c * 256 -bxor $Bytes[$offset + $j]
            $Bytes[$offset + $j] = [byte]([math]::Floor($c / 24))
            $c = $c % 24
        }
        $key = $map[$c] + $key
    }
    return $key
}

$winKey = $null
$digital = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DigitalProductId
if ($digital) {
    $full = ConvertFrom-DigitalProductId -Bytes $digital
    if ($full) { $winKey = $full.Substring($full.Length - 5) }
}

$officeKeys = @()
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\Licensing\License*' -ErrorAction SilentlyContinue |
    ForEach-Object {
        foreach ($p in $_.PSObject.Properties) {
            if ($p.Value -is [string] -and $p.Value -match '[BCDFGHJKMPQRTVWXY2346789]{5,}-') {
                $m = [regex]::Matches($p.Value, '[BCDFGHJKMPQRTVWXY2346789]{5}')
                if ($m.Count -ge 4) {
                    $officeKeys += $m[$m.Count - 1].Value
                }
            }
        }
    }

[pscustomobject]@{
    windows_key_last5   = $winKey
    office_keys_last5   = @($officeKeys | Select-Object -Unique)
    note                = 'Partial keys only - full product keys are never transmitted.'
} | ConvertTo-Json -Compress -Depth 3
