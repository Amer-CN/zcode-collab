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
# Resolve the project root by walking up from cwd to the nearest dir containing a
# .work/ folder with at least one briefing file (cwd may be a subdirectory the
# session cd'ed into). A "briefing file" is current-task.md OR task-*.md - the
# parallel-session naming the block message itself recommends.
$briefDir = $null
$probe = $cwd
try { $probe = [System.IO.Path]::GetFullPath($probe) } catch { $probe = $cwd }
while ($true) {
    $wd = Join-Path $probe '.work'
    if (Test-Path $wd) {
        $any = @(Get-ChildItem -Path $wd -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'current-task.md' -or $_.Name -like 'task-*.md' })
        if ($any.Count -gt 0) { $briefDir = $wd; break }
    }
    $parent = Split-Path $probe -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
    $probe = $parent
}

# All briefing files that could cover this session's edits
$briefFiles = @()
if ($null -ne $briefDir) {
    $briefFiles = @(Get-ChildItem -Path $briefDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'current-task.md' -or $_.Name -like 'task-*.md' })
}
$hasBrief = ($briefFiles.Count -gt 0)
$briefPath = $null
if ($hasBrief) { $briefPath = $briefFiles[0].FullName } else { $briefPath = Join-Path $cwd '.work\current-task.md' }

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
$delegatedTo = @{}
try {
    foreach ($line in [System.IO.File]::ReadLines($auditFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $rec = $null
        try { $rec = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $rec) { continue }
        if ($rec.ok -ne $true) { continue }
        $t = [string]$rec.target
        if ([string]::IsNullOrWhiteSpace($t)) { continue }

        # Real delegation signal: which subagents were actually dispatched this session.
        if ($rec.tool -eq 'Agent' -or $rec.tool -eq 'Task') {
            $delegatedTo[$t.ToLowerInvariant()] = $true
            continue
        }
        if ($rec.tool -ne 'Edit' -and $rec.tool -ne 'Write') { continue }

        # Non-production paths excluded from the count:
        #   .work/  .git/   task docs, briefings, commit-message temp files, locks
        #   ~/.zcode/       the collaboration system's own config tree (rules, agents,
        #                   hooks, hook-state, tmp) - same exemption enforce-flow applies.
        #                   NOTE: this means edits to the governance tooling itself are
        #                   NOT machine-gated; they rely on briefing + review discipline.
        #   system TEMP and common build/vendor dirs
        # Paths may arrive with either separator - normalise before comparing.
        $tn = ($t.ToLowerInvariant() -replace '/', '\')
        if ($t -match '(?i)(\.work|\.git)[\\/]') { continue }
        $zcodeRoot = ($homeDir + '\.zcode\').ToLowerInvariant() -replace '/', '\'
        if ($tn.StartsWith($zcodeRoot)) { continue }
        $sysTmp = [System.IO.Path]::GetTempPath()
        if ($sysTmp) {
            $st = ($sysTmp.ToLowerInvariant() -replace '/', '\')
            if ($tn.StartsWith($st)) { continue }
        }
        if ($tn -match '[\\/](node_modules|__pycache__|\.venv|venv|dist|build|target|\.next|\.cache)[\\/]') { continue }

        $edited[$t.ToLowerInvariant()] = $true
    }
} catch { Exit-Pass }

if ($edited.Count -ge 3) {
    # Two independent ways to satisfy the guard:
    #   1. REAL DELEGATION - executor (or code-reviewer) was actually dispatched this
    #      session; recorded by post-tool-audit.ps1 as target=subagent_type on Agent calls.
    #   2. DECLARATION - a briefing file in this project's .work/ (current-task.md or
    #      task-*.md, the parallel-session naming) covers every edited file (union).
    # Otherwise block, naming exactly which files are undeclared.
    $delegated = $delegatedTo.ContainsKey('executor') -or $delegatedTo.ContainsKey('code-reviewer')
    $allowedCover = $false
    $covered = 0
    $missing = @()
    if ($hasBrief) {
        try {
            $covered = 0
            foreach ($f in $edited.Keys) {
                $leaf = Split-Path $f -Leaf
                $hit = $false
                foreach ($bf in $briefFiles) {
                    $briefText = Get-Content $bf.FullName -Raw -Encoding UTF8
                    if ($briefText -match [regex]::Escape($leaf)) { $hit = $true; break }
                }
                if ($hit) { $covered++ } else { $missing += $leaf }
            }
            if ($covered -ge $edited.Count) { $allowedCover = $true }
        } catch { $allowedCover = $false }
    } else {
        foreach ($f in $edited.Keys) { $missing += (Split-Path $f -Leaf) }
    }
    if (-not $delegated -and -not $allowedCover) {
        $missList = ''
        if ($missing.Count -gt 0) {
            $show = @($missing | Select-Object -First 8)
            $missList = ' Undeclared: ' + ($show -join ', ')
            if ($missing.Count -gt 8) { $missList += ' (+' + ($missing.Count - 8) + ' more)' }
        }
        $req = "FLOW_DRIFT: This session edited " + $edited.Count + " distinct production files without executor dispatch (machine count from audit log)." + $missList + " Per AGENTS.md, cumulative edits >= 3 files must go through the B-class flow: write .work/task-<keyword>.md (own file per parallel session) listing every file you touch, dispatch executor with that exact path, then code-reviewer. Or add the undeclared files to a briefing if they were already authorized."
        try {
            $dbg = "ts=" + (Get-Date).ToUniversalTime().ToString('o') + " sid=" + $sid + " edited=" + $edited.Count + " covered=" + $covered + " delegated=" + $delegated + " briefs=" + $briefFiles.Count + " missing=" + ($missing -join '|')
            $db = [System.Text.Encoding]::UTF8.GetBytes($dbg + "`n")
            $df = Join-Path $homeDir '.zcode\cli\hooks\stop-debug.log'
            $fs = [System.IO.File]::Open($df, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try { $fs.Write($db, 0, $db.Length) } finally { $fs.Dispose() }
        } catch { }
        Exit-Block $req
    }
}

Exit-Pass
