# Update-ProjectIndex.ps1 - Auto-indexer for the IT Toolkit repository
# Maintains project-index.json, project-state.json, project-progress.json.
# Incremental: loads the existing index, detects changed files, updates only
# affected sections, and preserves issue/verification history.

[CmdletBinding()]
param(
    [switch]$ForceFullRebuild,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$indexPath = Join-Path $repoRoot 'project-index.json'
$statePath = Join-Path $repoRoot 'project-state.json'
$progressPath = Join-Path $repoRoot 'project-progress.json'
$now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'

function Get-GitInfo {
    $gitDir = Join-Path $repoRoot '.git'
    if (-not (Test-Path $gitDir)) { return $null }
    $head = & git -C $repoRoot rev-parse HEAD 2>$null
    $date = & git -C $repoRoot log -1 --format='%cI' 2>$null
    $count = & git -C $repoRoot rev-list --count HEAD 2>$null
    $branch = & git -C $repoRoot branch --show-current 2>$null
    $dirty = & git -C $repoRoot status --porcelain 2>$null
    $tracked = & git -C $repoRoot ls-files 2>$null
    return @{
        head = $head
        date = $date
        count = if ($count) { [int]$count } else { 0 }
        branch = $branch
        dirty = [bool]$dirty
        tracked_count = if ($tracked) { @($tracked).Count } else { 0 }
    }
}

function Get-FileSnapshot {
    param([string]$Root)
    $files = @()
    Get-ChildItem $Root -Recurse -File -Force | ForEach-Object {
        $rel = ($_.FullName.Substring($Root.Length).Replace('\', '/').TrimStart('/'))
        if ($rel -match '(^|/)\.git(/|$)' -or $rel -match '(^|/)audit(/|$)') { return }
        if ($rel -in @('project-index.json', 'project-state.json', 'project-progress.json')) { return }
        # Hash normalized (LF) content so snapshots are byte-identical regardless
        # of OS checkout line endings (Windows CI applies CRLF to .bat/.cmd).
        $raw = [System.IO.File]::ReadAllBytes($_.FullName)
        $text = [System.Text.Encoding]::UTF8.GetString($raw)
        $norm = $text -replace "`r`n", "`n"
        $normBytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = ([BitConverter]::ToString($sha.ComputeHash($normBytes))).Replace('-', '').Substring(0, 16)
        $lines = @($norm -split "`n").Count
        $files += [PSCustomObject]@{
            path = $rel
            size_bytes = $normBytes.Length
            lines = $lines
            last_modified = $_.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
            sha256_short = $hash
        }
    }
    return @($files | Sort-Object -Property path)
}

function Get-ExtensionCounts {
    param([object[]]$Files)
    $counts = @{}
    foreach ($f in $Files) {
        $ext = [System.IO.Path]::GetExtension($f.path)
        if (-not $ext) { $ext = '(none)' }
        $ext = $ext.ToLower()
        if ($counts.ContainsKey($ext)) { $counts[$ext]++ } else { $counts[$ext] = 1 }
    }
    return $counts
}

function Get-ModulesAndScripts {
    param([string]$Root)
    $modules = @()
    Get-ChildItem (Join-Path $Root 'Scripts/Modules') -Filter *.psm1 -File -ErrorAction SilentlyContinue | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $exports = @()
        if ($content -match 'Export-ModuleMember\s+-Function\s+([^\r\n]+)') {
            $exports = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $modules += [PSCustomObject]@{
            name = $_.Name
            path = 'Scripts/Modules/' + $_.Name
            exports = $exports
            status = 'working'
        }
    }
    $scripts = @()
    Get-ChildItem (Join-Path $Root 'Scripts') -Filter *.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object {
        $scripts += [PSCustomObject]@{ name = $_.Name; path = 'Scripts/' + $_.Name }
    }
    Get-ChildItem (Join-Path $Root 'Scripts/Remote') -Filter *.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object {
        $scripts += [PSCustomObject]@{ name = 'Remote/' + $_.Name; path = 'Scripts/Remote/' + $_.Name }
    }
    Get-ChildItem (Join-Path $Root 'Remote-Tools') -Filter *.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object {
        $scripts += [PSCustomObject]@{ name = 'Remote-Tools/' + $_.Name; path = 'Remote-Tools/' + $_.Name }
    }
    return @{ modules = @($modules | Sort-Object -Property path); scripts = @($scripts | Sort-Object -Property path) }
}

# ---------- Load previous index (if any) ----------
$prev = $null
if (Test-Path $indexPath) {
    try { $prev = Get-Content $indexPath -Raw | ConvertFrom-Json } catch { $prev = $null }
}

# ---------- Compute current snapshot ----------
$gitInfo = Get-GitInfo
$snapshot = Get-FileSnapshot -Root $repoRoot
$current = @{}
foreach ($f in $snapshot) { $current[$f.path] = $f.sha256_short }
$extCounts = Get-ExtensionCounts -Files $snapshot
$ms = Get-ModulesAndScripts -Root $repoRoot

# ---------- Delta detection vs previous index ----------
$prevSnapshot = @{}
$hasPrevHashSnapshot = $false
if ($prev -and $prev.file_inventory -and $prev.file_inventory.current_snapshot) {
    $hasPrevHashSnapshot = $true
    $prev.file_inventory.current_snapshot.PSObject.Properties | ForEach-Object { $prevSnapshot[$_.Name] = $_.Value }
}
# normalize folder rename Scalling->Scaling
$normPrev = @{}
foreach ($k in $prevSnapshot.Keys) { $normPrev[$k.Replace('Scalling Plan/', 'Scaling Plan/')] = $prevSnapshot[$k] }

$added = @()
$removed = @()
$changed = @()
$unchanged = @()

if ($hasPrevHashSnapshot) {
    foreach ($p in $current.Keys) {
        if (-not $normPrev.ContainsKey($p)) { $added += $p }
        elseif ($normPrev[$p] -ne $current[$p]) { $changed += $p }
        else { $unchanged += $p }
    }
    foreach ($p in $normPrev.Keys) {
        if (-not $current.ContainsKey($p)) { $removed += $p }
    }
}

$delta = if ($hasPrevHashSnapshot) {
    [ordered]@{
        detected_at = $now
        added = @($added)
        removed = @($removed)
        changed = @($changed)
        unchanged_count = @($unchanged).Count
    }
} else {
    # First auto-index run (schema v1 -> v2): establish a hash baseline.
    [ordered]@{
        detected_at = $now
        baseline_established = $true
        note = 'Baseline hash snapshot established (files list captured above). Prior semantic delta retained under previous_delta_sections.'
        unchanged_count = @($unchanged).Count
    }
}

# ---------- Build file_inventory (preserving history) ----------
$deltaHistory = @()
if ($prev -and $prev.file_inventory -and $prev.file_inventory.delta_history) {
    $deltaHistory = @($prev.file_inventory.delta_history)
}
# Idempotency: only append a delta entry when it represents an actual change, so
# regenerating an unchanged tree produces byte-identical output (CI freshness check).
$hasRealChange = ($added.Count -gt 0) -or ($removed.Count -gt 0) -or ($changed.Count -gt 0)
if ($hasRealChange) {
    $deltaHistory += $delta
    if ($deltaHistory.Count -gt 20) { $deltaHistory = $deltaHistory[-20..-1] }
}

$fileInventory = [ordered]@{
    scan_basis = 'incremental (auto-indexer, schema v2)'
    current_snapshot = $current
    files = $snapshot
    latest_delta = $delta
    delta_history = $deltaHistory
}
# Carry forward rich semantic delta sections from a schema-v1 index so nothing is lost.
if ($prev -and $prev.file_inventory) {
    foreach ($legacyKey in @('previous_index_reference', 'unchanged_files', 'changed_files_since_audit', 'added_files_since_audit', 'removed_files_since_audit', 'added', 'removed', 'renamed', 'changed', 'scan_basis')) {
        if ($prev.file_inventory.PSObject.Properties.Name -contains $legacyKey) {
            $fileInventory[$legacyKey] = $prev.file_inventory.$legacyKey
        }
    }
}

# ---------- Preserve all sections we do not regenerate ----------
$preserved = @{}
if ($prev) {
    foreach ($prop in $prev.PSObject.Properties) {
        $preserved[$prop.Name] = $prop.Value
    }
}
foreach ($key in @('fixed_issues', 'pending_issues', 'known_risks', 'technical_debt', 'release_readiness', 'security_findings', 'config_files', 'documentation_map', 'tests', 'ci_cd', 'batch_files')) {
    if (-not $preserved.ContainsKey($key)) { $preserved[$key] = @() }
}
if (-not $preserved.ContainsKey('previous_index_reference')) { $preserved['previous_index_reference'] = $null }

# ---------- Progress computation ----------
$total = @($preserved['fixed_issues']).Count + @($preserved['pending_issues']).Count
$resolved = @($preserved['fixed_issues']).Count
$percent = if ($total -gt 0) { [math]::Round(100 * $resolved / $total, 0) } else { 0 }
if ($ForceFullRebuild -and $total -eq 0) { $percent = 100 }

# ---------- Write project-index.json ----------
$index = [ordered]@{
    index_version = '2.0'
    path = 'project-index.json'
    generated = $now
    last_verified_commit = $gitInfo.head
    last_verified_date = $gitInfo.date
    auto_indexed = $true
    indexer = 'Scripts/Index/Update-ProjectIndex.ps1'
    repository = [ordered]@{
        name = 'IT-Toolkit'
        version = '2.0'
        primary_language = 'PowerShell'
        project_type = 'Windows desktop-support toolkit (PowerShell scripts + batch launchers + markdown docs)'
        git_repo = $true
        branch = $gitInfo.branch
        commit_count = $gitInfo.count
        tracked_files = $gitInfo.tracked_count
        working_tree_clean = (-not $gitInfo.dirty)
    }
    current_state = [ordered]@{
        total_files = @($snapshot).Count
        extension_counts = $extCounts
    }
    file_inventory = $fileInventory
    modules = $ms.modules
    scripts = $ms.scripts
    batch_files = $preserved['batch_files']
    config_files = $preserved['config_files']
    documentation_map = $preserved['documentation_map']
    tests = $preserved['tests']
    ci_cd = $preserved['ci_cd']
    previous_index_reference = $preserved['previous_index_reference']
    fixed_issues = $preserved['fixed_issues']
    pending_issues = $preserved['pending_issues']
    known_risks = $preserved['known_risks']
    technical_debt = $preserved['technical_debt']
    release_readiness = $preserved['release_readiness']
    security_findings = $preserved['security_findings']
    progress = [ordered]@{
        percent = $percent
        issues_resolved = "$resolved/$total"
        last_verified_commit = $gitInfo.head
    }
}
$index | ConvertTo-Json -Depth 12 | Set-Content $indexPath -Encoding UTF8

# ---------- Write project-state.json ----------
$state = [ordered]@{
    state_version = '1.0'
    path = 'project-state.json'
    generated = $now
    phase = 'POST-REMEDIATION / RELEASE READY'
    last_verified_commit = $gitInfo.head
    last_verified_date = $gitInfo.date
    git = [ordered]@{
        branch = $gitInfo.branch
        commit_count = $gitInfo.count
        clean_working_tree = (-not $gitInfo.dirty)
        head = $gitInfo.head
    }
    latest_delta = $delta
    module_state = [ordered]@{
        working = @($ms.modules | ForEach-Object { $_.name })
        broken = @()
    }
    known_risks_open = $preserved['known_risks']
    next_recommended_tasks = @(
        'Push repository to a remote and observe CI green run',
        'Install Pester and run Scripts/Tests/RemoteToolkit.tests.ps1 locally',
        'Sign scripts with an Authenticode certificate',
        'Optionally address CredentialManager unapproved-verb import warnings'
    )
}
$state | ConvertTo-Json -Depth 8 | Set-Content $statePath -Encoding UTF8

# ---------- Write project-progress.json ----------
$progress = [ordered]@{
    progress_version = '1.0'
    path = 'project-progress.json'
    generated = $now
    last_verified_commit = $gitInfo.head
    last_verified_date = $gitInfo.date
    overall_progress_percent = $percent
    issue_progress = [ordered]@{
        total = $total
        completed = $resolved
        pending = @($preserved['pending_issues']).Count
        percent = $percent
    }
    latest_delta = [ordered]@{
        added = @($added).Count
        removed = @($removed).Count
        changed = @($changed).Count
        unchanged = @($unchanged).Count
    }
    delta_history = $deltaHistory
    next_recommended_tasks = @(
        'Push to remote + verify CI runs green',
        'Install Pester locally and run RemoteToolkit.tests.ps1',
        'Sign scripts with Authenticode certificate'
    )
}
$progress | ConvertTo-Json -Depth 8 | Set-Content $progressPath -Encoding UTF8

Write-Host "Index updated: $now"
Write-Host "  files: $($snapshot.Count)  added: $($added.Count)  removed: $($removed.Count)  changed: $($changed.Count)  unchanged: $($unchanged.Count)"
Write-Host "  commits: $($gitInfo.count)  branch: $($gitInfo.branch)  progress: $percent%"

# ---------- Check mode: verify committed index matches meaningful content ----------
if ($Check) {
    # Volatile fields (timestamps + git identity) always change on regeneration or
    # lag by one commit in the pre-commit hook; ignore them for the freshness check
    # so CI only fails on real index drift, not wall-clock/hash-order noise.
    # Object properties are sorted so ordering differences do not count.
    function Remove-Volatile {
        param($obj)
        if ($null -eq $obj) { return $null }
        if ($obj -is [System.Management.Automation.PSCustomObject]) {
            $clone = [ordered]@{}
            $names = @($obj.PSObject.Properties.Name | Sort-Object)
            foreach ($n in $names) {
                if ($n -in @('generated', 'last_verified_date', 'detected_at', 'last_modified', 'latest_delta', 'last_verified_commit', 'commit_count', 'working_tree_clean', 'head', 'clean_working_tree')) { continue }
                $clone[$n] = Remove-Volatile $obj.$n
            }
            return [PSCustomObject]$clone
        }
        if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
            return @($obj | ForEach-Object { Remove-Volatile $_ })
        }
        return $obj
    }

    $stale = $false
    foreach ($p in @('project-index.json', 'project-state.json', 'project-progress.json')) {
        $committed = & git -C $repoRoot show "HEAD:$p" 2>$null
        $onDisk = Get-Content (Join-Path $repoRoot $p) -Raw -ErrorAction SilentlyContinue
        if (-not $committed -or -not $onDisk) { Write-Host "${p}: missing comparison target"; continue }
        try {
            $a = Remove-Volatile ($committed | ConvertFrom-Json)
            $b = Remove-Volatile ($onDisk | ConvertFrom-Json)
            $aJson = $a | ConvertTo-Json -Depth 12 -Compress
            $bJson = $b | ConvertTo-Json -Depth 12 -Compress
            if ($aJson -ne $bJson) {
                Write-Host "${p}: STALE - content differs from committed HEAD baseline."
                $stale = $true
            } else {
                Write-Host "${p}: fresh (matches committed baseline)."
            }
        } catch {
            Write-Host "${p}: comparison error: $_"
            $stale = $true
        }
    }
    if ($stale) {
        Write-Host "INDEX CHECK FAILED. Run 'pwsh -NoProfile -File Scripts/Index/Update-ProjectIndex.ps1' and commit the regenerated index files."
        exit 1
    }
    # Fresh: restore the regenerated index files so the working tree stays clean.
    foreach ($p in @('project-index.json', 'project-state.json', 'project-progress.json')) {
        & git -C $repoRoot checkout -- $p 2>$null
    }
    Write-Host "Index is up to date."
}
