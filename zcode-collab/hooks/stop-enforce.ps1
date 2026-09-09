# stop-enforce.ps1
# ZCode Stop hook (revised 2026-09-09: machine counting + brief coverage + brief-path hint).
# Two checks at end of each assistant turn:
#   CHECK 1 (no-briefing guard): project dir has no .work/current-task.md AND this turn
#             did write operations -> block, ask for a briefing.
#   CHECK 2 (cumulative drift guard): count distinct production files edited in THIS
#             session from the PostToolUse audit log; if >= 3 and executor was never
#             dispatched in this session -> block, ask to route via executor.
# Both checks are fail-open (any read error = pass, never block the chain).
#
# Event: Stop
# stdin JSON: { cwd, sessionId, messages, ... }

$ErrorActionPreference = 'Stop'

function Exit-Pass { exit 0 }

function Exit-Block([string]$reason) {
    try {
        $b = [System.Text.Encoding]::UTF8.GetBytes($reason)
        [Console]::OpenStandardError().Write($b, 0, $b.Length)
    } catch {
        try { [Console]::Error.WriteLine($reason) } catch {}
    }
    exit 2
}

# ---- read stdin raw bytes, decode UTF-8 ----
$raw = $null
try {
    $ms = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($ms)
    $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
} catch { $raw = $null }

if ([string]::IsNullOrWhiteSpace($raw)) { Exit-Pass }

try {
    $obj = $raw | ConvertFrom-Json
} catch {
    Exit-Pass
}

$cwd = $null
if ($obj.PSObject.Properties.Name -contains 'cwd' -and $obj.cwd) {
    $cwd = [string]$obj.cwd
}
if (-not $cwd) {
    $cwd = [Environment]::GetEnvironmentVariable('ZCODE_PROJECT_DIR')
}
if (-not $cwd) {
    $cwd = [Environment]::GetEnvironmentVariable('CLAUDE_PROJECT_DIR')
}
if ([string]::IsNullOrWhiteSpace($cwd)) { Exit-Pass }

$sid = ''
if ($obj.PSObject.Properties.Name -contains 'sessionId' -and $obj.sessionId) {
    $sid = [string]$obj.sessionId
}

# ---- CHECK 1: briefing file presence ----
# Resolve the project root by walking up from cwd to the nearest dir containing
# .work/current-task.md (cwd may be a subdirectory the session cd'ed into).
$briefPath = $null
$probe = $cwd
try { $probe = [System.IO.Path]::GetFullPath($probe) } catch { $probe = $cwd }
while ($true) {
    $cand = Join-Path $probe '.work\current-task.md'
    if (Test-Path $cand) { $briefPath = $cand; break }
    $parent = Split-Path $probe -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
    $probe = $parent
}
if ($null -eq $briefPath) {
    # No briefing anywhere up the tree: fall back to cwd-level path for messaging
    $briefPath = Join-Path $cwd '.work\current-task.md'
}
$hasBrief = Test-Path $briefPath

# ---- detect write operations in this turn's messages ----
$hadWrite = $false
$messages = @()
if ($obj.PSObject.Properties.Name -contains 'messages') { $messages = $obj.messages }

foreach ($msg in $messages) {
    if (-not ($msg -is [System.Management.Automation.PSCustomObject])) { continue }
    if ($msg.role -ne 'assistant') { continue }
    $content = $msg.content
    if ($content -is [string]) {
        if ($content -match 'edit|write|multi.edit|apply.patch|git\s+(add|commit|push)') {
            $hadWrite = $true; break
        }
    } elseif ($content -is [System.Array]) {
        foreach ($item in $content) {
            if ($item -is [System.Management.Automation.PSCustomObject]) {
                $txt = ''
                if ($item.text) { $txt = [string]$item.text }
                elseif ($item.content) { $txt = [string]$item.content }
                if ($txt -match 'edit|write|multi.edit|apply.patch') {
                    $hadWrite = $true; break
                }
            }
        }
        if ($hadWrite) { break }
    }
}

if (-not $hasBrief -and $hadWrite) {
    $req = "BRIEF_MISSING: You are working in project '$cwd' but no task briefing (.work/current-task.md) exists. Create the briefing following AGENTS.md section '写简报' before making further code changes. If parallel sessions are running in this project, give this briefing its own file (.work/task-<keyword>.md) and pass that exact path when dispatching executor/code-reviewer."
    Exit-Block $req
}

# ---- CHECK 2: cumulative drift guard (machine count from audit log) ----
# Count distinct non-.work files this session successfully edited.
$sessionIdSafe = ($sid -replace '[^a-zA-Z0-9_-]', '_')
if ([string]::IsNullOrWhiteSpace($sessionIdSafe)) { Exit-Pass }

$homeDir = $env:USERPROFILE
if (-not $homeDir) { $homeDir = [System.Environment]::GetFolderPath('UserProfile') }
$auditFile = Join-Path $homeDir ('.zcode\cli\hooks\activity-' + $sessionIdSafe + '.log')
if (-not (Test-Path $auditFile)) { Exit-Pass }

$edited = @{}
try {
    foreach ($line in [System.IO.File]::ReadLines($auditFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $rec = $null
        try { $rec = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $rec) { continue }
        if ($rec.tool -ne 'Edit' -and $rec.tool -ne 'Write') { continue }
        if ($rec.ok -ne $true) { continue }
        $t = [string]$rec.target
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        # .work/ docs (briefings, reports) don't count toward the drift threshold
        if ($t -match '(?i)\.work[\\/]') { continue }
        $edited[$t.ToLowerInvariant()] = $true
    }
} catch { Exit-Pass }

if ($edited.Count -ge 3) {
    # Was executor dispatched in this session? Executor's own audit trail lives in
    # the subagent session log, not here; check via recent Agent tool records instead.
    # Cheap heuristic: if a .work/task-*.md briefing exists for this project AND the
    # current-task.md allows-list covers these files, assume flow is being followed.
    # Otherwise block with a routing instruction.
    $allowedCover = $false
    if ($hasBrief) {
        try {
            $briefText = Get-Content $briefPath -Raw -Encoding UTF8
            $covered = 0
            foreach ($f in $edited.Keys) {
                $leaf = Split-Path $f -Leaf
                if ($briefText -match [regex]::Escape($leaf)) { $covered++ }
            }
            if ($covered -ge $edited.Count) { $allowedCover = $true }
        } catch { $allowedCover = $false }
    }
    if (-not $allowedCover) {
        $req = "FLOW_DRIFT: This session edited " + $edited.Count + " distinct production files without executor dispatch (machine count from audit log). Per AGENTS.md, cumulative edits >= 3 files must go through the B-class flow: write .work/task-<keyword>.md (own file per parallel session), dispatch executor with that exact path, then code-reviewer. Create the briefing now."
        try {
            $dbg = "ts=" + (Get-Date).ToUniversalTime().ToString('o') + " sid=" + $sid + " safe=" + $sessionIdSafe + " audit=" + $auditFile + " edited=" + $edited.Count + " covered=" + $covered + " brief=" + $briefPath
            $db = [System.Text.Encoding]::UTF8.GetBytes($dbg + "`n")
            $df = Join-Path $homeDir '.zcode\cli\hooks\stop-debug.log'
            $fs = [System.IO.File]::Open($df, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try { $fs.Write($db, 0, $db.Length) } finally { $fs.Dispose() }
        } catch { }
        Exit-Block $req
    }
}

Exit-Pass
