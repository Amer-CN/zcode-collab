# enforce-flow.ps1 - flow-enforcement hook for ZCode (PreToolUse)
# Blocks a code edit when it would push this session past 3 UNDECLARED production
# files. "Declared" = the file's name appears in a task briefing under the project's
# .work/ (current-task.md OR any task-*.md - the parallel-session naming AGENTS.md
# prescribes). Same coverage semantics as stop-enforce.ps1 (one authoritative rule).
#
# Invoked by ZCode as a process-type hook:
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <this file>
# Input : PreToolUse event JSON on stdin (tool_name / tool_input.file_path / session_id / cwd)
#         with env-var fallbacks: ZCODE_SESSION_ID / CLAUDE_SESSION_ID,
#         ZCODE_PROJECT_DIR / CLAUDE_PROJECT_DIR.
# Output: exit 0 = allow (stdout kept empty - hook stdout is parsed as strict JSON)
#         exit 2 = block (message written to stderr)
# State : C:\Users\Admin\.zcode\cli\hook-state\state-<sha256(project|session)>.json
#         fields: seen (deduped list of production paths touched this session).
#         Coverage is recomputed on every call, so adding a file to a briefing
#         un-blocks it immediately (self-healing; no permanent per-session pass).

$ErrorActionPreference = 'Stop'

function Exit-Pass { exit 0 }

function Exit-Block([string]$reason) {
    try {
        $b = [System.Text.Encoding]::UTF8.GetBytes($reason)
        [Console]::OpenStandardError().Write($b, 0, $b.Length)
    } catch {
        try { [Console]::Error.WriteLine($reason) } catch { }
    }
    exit 2
}

function Get-StatePath([string]$proj, [string]$sid, [string]$usrHome) {
    $dir = Join-Path $usrHome '.zcode\cli\hook-state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($sid) { $k = $proj.ToLowerInvariant() + '|' + $sid } else { $k = $proj.ToLowerInvariant() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hb = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($k))
    $hex = -join ($hb | ForEach-Object { $_.ToString('x2') })
    return (Join-Path $dir ("state-" + $hex + ".json"))
}

# ---- briefing discovery: nearest .work/ up the tree holding current-task.md or task-*.md ----
function Get-BriefFiles([string]$proj) {
    $probe = $proj
    while ($true) {
        $wd = Join-Path $probe '.work'
        if (Test-Path $wd) {
            $c = @(Get-ChildItem -Path $wd -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'current-task.md' -or $_.Name -like 'task-*.md' })
            if ($c.Count -gt 0) { return $c }
        }
        $parent = Split-Path $probe -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { return @() }
        $probe = $parent
    }
}

# ---- coverage: does any briefing mention this file (by file name)? ----
function Test-Declared([string]$file, $briefs) {
    if ($null -eq $briefs -or $briefs.Count -eq 0) { return $false }
    $leaf = Split-Path $file -Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $false }
    foreach ($b in $briefs) {
        try {
            $txt = Get-Content $b.FullName -Raw -Encoding UTF8
            if ($txt -match [regex]::Escape($leaf)) { return $true }
        } catch { }
    }
    return $false
}

# ---- read stdin JSON ----
$json = $null
try { $raw = [Console]::In.ReadToEnd() } catch { $raw = $null }

if (-not [string]::IsNullOrWhiteSpace($raw)) { try { $json = $raw | ConvertFrom-Json } catch { $json = $null } }

# ---- extract fields: JSON first, env-var fallback ----
$sessionId = $null
if ($json -and ($json.PSObject.Properties.Name -contains 'session_id') -and $json.session_id) { $sessionId = [string]$json.session_id }
if (-not $sessionId) {
    $sessionId = [Environment]::GetEnvironmentVariable('ZCODE_SESSION_ID')
    if (-not $sessionId) { $sessionId = [Environment]::GetEnvironmentVariable('CLAUDE_SESSION_ID') }
}

$projectDir = $null
if ($json -and ($json.PSObject.Properties.Name -contains 'cwd') -and $json.cwd) { $projectDir = [string]$json.cwd }
if (-not $projectDir) {
    $projectDir = [Environment]::GetEnvironmentVariable('ZCODE_PROJECT_DIR')
    if (-not $projectDir) { $projectDir = [Environment]::GetEnvironmentVariable('CLAUDE_PROJECT_DIR') }
}

$target = $null
if ($json -and ($json.PSObject.Properties.Name -contains 'tool_input') -and $json.tool_input) {
    $ti = $json.tool_input
    if ($ti.PSObject.Properties.Name -contains 'file_path' -and $ti.file_path) { $target = [string]$ti.file_path }
    elseif ($ti.PSObject.Properties.Name -contains 'path' -and $ti.path) { $target = [string]$ti.path }
}

# No target path or project dir: allow without counting (fail-open, avoid false blocks)
if (-not $target -or -not $projectDir) { Exit-Pass }

try {
    $target = [System.IO.Path]::GetFullPath($target)
    $projectDir = [System.IO.Path]::GetFullPath($projectDir)
} catch { Exit-Pass }

# ---- never-count paths: config tree (~/.zcode) ----
$homeDir = $env:USERPROFILE
if (-not $homeDir) { $homeDir = [System.Environment]::GetFolderPath('UserProfile') }
$zcodeRoot = [System.IO.Path]::GetFullPath((Join-Path $homeDir '.zcode'))
if ($target.StartsWith($zcodeRoot, [System.StringComparison]::OrdinalIgnoreCase)) { Exit-Pass }

# ---- never-count paths: anything under .work\ or .work/ (briefings, reports) ----
if ($target -match '(?i)\.work[\\/]') { Exit-Pass }

# ---- never-count paths: .git/ internals (commit-message temp files, locks) ----
if ($target -match '(?i)\.git[\\/]') { Exit-Pass }

# ---- state file path (same key for the whole event) ----
$statePath = Get-StatePath $projectDir $sessionId $homeDir

# ---- load state; 2h expiry only when no session id (stale resets) ----
$seen = @()
if (Test-Path $statePath) {
    try {
        $last = (Get-Item $statePath).LastWriteTimeUtc
        $stale = $false
        if (-not $sessionId) {
            if (((Get-Date).ToUniversalTime() - $last).TotalHours -gt 2) { $stale = $true }
        }
        if (-not $stale) {
            $st = Get-Content $statePath -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($st.PSObject.Properties.Name -contains 'seen') { $seen = @($st.seen) }
            elseif ($st.PSObject.Properties.Name -contains 'files') { $seen = @($st.files) }
        }
    } catch { $seen = @() }
}

# ---- normal file: append (dedup), persist, then decide ----
$dup = $false
foreach ($f in $seen) {
    if ([string]::Equals($f, $target, [System.StringComparison]::OrdinalIgnoreCase)) { $dup = $true; break }
}
if (-not $dup) { $seen += $target }

$st = @{ seen = $seen } | ConvertTo-Json -Compress -Depth 5
Set-Content -Path $statePath -Value $st -Encoding UTF8

# ---- decision: count files NOT declared in any briefing; 3+ -> block ----
$briefs = Get-BriefFiles $projectDir

if (Test-Declared $target $briefs) { Exit-Pass }

$undeclared = @()
foreach ($f in $seen) {
    if (-not (Test-Declared $f $briefs)) { $undeclared += (Split-Path $f -Leaf) }
}

if ($undeclared.Count -ge 3) {
    $show = @($undeclared | Select-Object -First 8)
    $list = $show -join ', '
    if ($undeclared.Count -gt 8) { $list += ' (+' + ($undeclared.Count - 8) + ' more)' }
    Exit-Block ("FLOW_GATE: this session has touched " + $undeclared.Count + " production files that no task briefing declares. Undeclared: " + $list + " . Per AGENTS.md, cumulative edits >= 3 files must go through the B-class flow: write .work/task-<keyword>.md (own file per parallel session) listing the files you touch, dispatch executor with that exact path, then code-reviewer. Add these names to a briefing to proceed.")
}

Exit-Pass
