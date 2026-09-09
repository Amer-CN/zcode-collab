# enforce-flow.ps1 - flow-enforcement hook for ZCode
# Blocks the 3rd file modification in a window where no task briefing was written.
# Invoked by ZCode as a process-type hook:
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <this file>
# Input : PreToolUse event JSON on stdin (tool_name / tool_input.file_path / session_id / cwd)
#         with env-var fallbacks: ZCODE_SESSION_ID / CLAUDE_SESSION_ID,
#         ZCODE_PROJECT_DIR / CLAUDE_PROJECT_DIR.
# Output: exit 0 = allow (stdout kept empty - hook stdout is parsed as strict JSON)
#         exit 2 = block (message written to stderr)
# State : C:\Users\Admin\.zcode\cli\hook-state\state-<sha256(project|session)>.json
#         fields: files (deduped list of counted absolute paths), briefWritten (bool, starts false)

$ErrorActionPreference = 'Stop'

# Block message (verbatim, UTF-8; stored base64 so the file is encoding-independent)
$BLOCK_MSG = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5bey6L+e57ut5pS55YqoIDMg5Liq5paH5Lu25LiU5pys5qyh5pyq5YaZ5Lu75Yqh566A5oql44CC5oyJ5Y2P5L2c5rWB56iL5bqU5YWI5YaZIC53b3JrL2N1cnJlbnQtdGFzay5tZCDlho3osIPnlKggZXhlY3V0b3LjgILoi6Xnoa7orqTopoHot7Pov4fmtYHnqIvvvIzor7fnlLHnlKjmiLfmmI7noa7mjIfnpLrjgII='))

function Exit-Pass { exit 0 }

function Exit-Block {
    try { [Console]::Error.WriteLine($BLOCK_MSG) } catch { try { $host.UI.WriteErrorLine($BLOCK_MSG) } catch {} }
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

# ---- state file path (same key for the whole event) ----
$statePath = Get-StatePath $projectDir $sessionId $homeDir

# ---- writing the briefing: reset the counting window ----
# Criterion is "was a briefing written in THIS counting window", never "does the file exist".
# Path-matched by regex: immune to slash direction / case / relative-vs-absolute / wrong $projectDir.
if ($target -match '(?i)[\\/]?\.work[\\/]current-task\.md$') {
    $st = @{ files = @(); briefWritten = $true } | ConvertTo-Json -Compress -Depth 5
    Set-Content -Path $statePath -Value $st -Encoding UTF8
    Exit-Pass
}

# ---- never-count paths: anything under .work\ or .work/ ----
if ($target -match '(?i)\.work[\\/]') { Exit-Pass }

# ---- load state; 2h expiry only when no session id (stale resets) ----
$files = @()
$briefWritten = $false
if (Test-Path $statePath) {
    try {
        $last = (Get-Item $statePath).LastWriteTimeUtc
        $stale = $false
        if (-not $sessionId) {
            if (((Get-Date).ToUniversalTime() - $last).TotalHours -gt 2) { $stale = $true }
        }
        if (-not $stale) {
            $st = Get-Content $statePath -Encoding UTF8 -Raw | ConvertFrom-Json
            $files = @($st.files)
            $briefWritten = [bool]$st.briefWritten
        }
    } catch { $files = @(); $briefWritten = $false }
}

# ---- normal file: append (dedup) then decide ----
$dup = $false
foreach ($f in $files) {
    if ([string]::Equals($f, $target, [System.StringComparison]::OrdinalIgnoreCase)) { $dup = $true; break }
}
if (-not $dup) { $files += $target }

$st = @{ files = $files; briefWritten = $briefWritten } | ConvertTo-Json -Compress -Depth 5
Set-Content -Path $statePath -Value $st -Encoding UTF8

if ($files.Count -ge 3 -and -not $briefWritten) { Exit-Block }

Exit-Pass