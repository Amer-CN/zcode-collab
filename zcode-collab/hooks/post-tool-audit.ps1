# post-tool-audit.ps1
# ZCode hook: on PostToolUse, append an audit record to a per-session log file.
# Records: timestamp, sessionId, toolName, target (file path or command text), ok, latency.
# Machine-generated audit trail; the model cannot influence it.
#
# Event: PostToolUse
# stdin: JSON { toolName, tool_input, sessionId, success, durationMs, ... }
# Output: exit 0 = pass (stdout kept empty)
#
# PS 5.1 compatible: no ?? operator, no ternary. Field access via PSObject checks.

$ErrorActionPreference = 'Stop'

function Exit-Pass { exit 0 }

# ---- read stdin as raw bytes, decode UTF-8 (console codepage would mangle) ----
$raw = $null
try {
    $ms = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($ms)
    $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
} catch { $raw = $null }

if ([string]::IsNullOrWhiteSpace($raw)) { Exit-Pass }

# ---- parse JSON ----
$obj = $null
try { $obj = $raw | ConvertFrom-Json } catch { Exit-Pass }
if ($null -eq $obj) { Exit-Pass }

# ---- extract fields (PS 5.1 safe) ----
function Get-Field($o, [string]$name) {
    if ($null -eq $o) { return $null }
    if ($o.PSObject.Properties.Name -contains $name) { return $o.$name }
    return $null
}

$toolName = [string](Get-Field $obj 'toolName')
$sid = [string](Get-Field $obj 'sessionId')
if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [Environment]::GetEnvironmentVariable('ZCODE_SESSION_ID') }
if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [Environment]::GetEnvironmentVariable('CLAUDE_SESSION_ID') }
if ([string]::IsNullOrWhiteSpace($sid)) { $sid = 'unknown' }

$success = Get-Field $obj 'success'
$ok = $true
if ($success -is [bool]) { $ok = $success }
elseif ("$success" -eq 'false' -or "$success" -eq 'False') { $ok = $false }

$durationMs = Get-Field $obj 'durationMs'
if ($null -eq $durationMs) { $durationMs = 0 }

$ti = Get-Field $obj 'tool_input'

# ---- determine target: file path for edit tools, command text for Bash ----
$target = ''
if ($null -ne $ti) {
    if ($toolName -eq 'Bash') {
        $target = Get-Field $ti 'command'
        if ([string]::IsNullOrWhiteSpace("$target")) { $target = Get-Field $ti 'cmd' }
        if ([string]::IsNullOrWhiteSpace("$target")) { $target = Get-Field $ti 'input' }
        $target = [string]$target
        if ($target.Length -gt 200) { $target = $target.Substring(0, 200) + '...' }
    } else {
        $target = Get-Field $ti 'file_path'
        if ([string]::IsNullOrWhiteSpace("$target")) { $target = Get-Field $ti 'path' }
        if ([string]::IsNullOrWhiteSpace("$target")) { $target = Get-Field $ti 'filename' }
        $target = [string]$target
    }
}

# ---- resolve log dir (same dir as the hook scripts) ----
$homeDir = $env:USERPROFILE
if (-not $homeDir) { $homeDir = [System.Environment]::GetFolderPath('UserProfile') }
$hookDir = Join-Path $homeDir '.zcode\cli\hooks'
if (-not (Test-Path $hookDir)) { New-Item -ItemType Directory -Path $hookDir -Force | Out-Null }

# per-session log file: avoids concurrent write corruption
$sessionIdSafe = ($sid -replace '[^a-zA-Z0-9_-]', '_')
if ($sessionIdSafe.Length -gt 60) { $sessionIdSafe = $sessionIdSafe.Substring(0, 60) }
$logFile = Join-Path $hookDir ("activity-" + $sessionIdSafe + ".log")

# ---- build record (single-line JSON) ----
$ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$record = @{
    ts      = $ts
    sid     = $sessionIdSafe
    tool    = $toolName
    target  = $target
    ok      = $ok
    latency = $durationMs
} | ConvertTo-Json -Compress

# ---- append; silent-fail so the hook never blocks the tool chain ----
# Append raw UTF-8 bytes (no BOM) so every line stays clean JSON for line-by-line parsing.
try {
    $line = $record + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $fs = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
} catch { }

Exit-Pass
