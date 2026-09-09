# session-start-enforce.ps1
# ZCode hook: on SessionStart (startup/resume), inject a discipline reminder.
# Checks that ~/.zcode/AGENTS.md still references the PostToolUse audit mechanism.
# On resume, logs a light reminder about the audit log location.
#
# Event: SessionStart
# match value (stdin mode field): startup / resume / clear / compact
# Output: exit 0 with optional additionalContext JSON

$ErrorActionPreference = 'Stop'

function Exit-Pass([string]$context = '') {
    if ($context) {
        $out = @{ additionalContext = $context } | ConvertTo-Json -Compress
        [Console]::Out.Write($out)
    }
    exit 0
}

# ---- read stdin ----
$raw = $null
try { $raw = [Console]::In.ReadToEnd() } catch { $raw = $null }
if ([string]::IsNullOrWhiteSpace($raw)) { Exit-Pass }

# ---- parse mode ----
$mode = ''
try {
    $obj = $raw | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains 'mode' -and $obj.mode) { $mode = $obj.mode }
    elseif ($obj.PSObject.Properties.Name -contains 'type' -and $obj.type) { $mode = $obj.type }
    else { $mode = '' }
} catch {
    $mode = $raw.Trim()
}

# clear/compact: no reminder needed
if ($mode -eq 'clear' -or $mode -eq 'compact') { Exit-Pass }

# ---- check AGENTS.md for audit mechanism description ----
$agentsMd = Join-Path $env:USERPROFILE '.zcode\AGENTS.md'
$hasAuditMechanism = $false
try {
    $content = Get-Content $agentsMd -Raw -Encoding UTF8
    # Check for PostToolUse audit mechanism reference (replaced self-check line on 2026-09-05)
    $hasAuditMechanism = ($content -match 'PostToolUse.*钩子' -or $content -match 'activity-.*\.log')
} catch {
    $hasAuditMechanism = $false
}

if (-not $hasAuditMechanism) {
    $ctx = 'WARNING: ~/.zcode/AGENTS.md is missing the PostToolUse audit mechanism description. Please verify the collaboration system is still deployed. See AGENTS.md "汇报纪律" section.'
    Exit-Pass $ctx
}

# ---- inject light reminder on resume ----
if ($mode -eq 'resume') {
    $ctx = '[Collaboration mode] New session recovered. Code edits are now auto-audited to ~/.zcode/cli/hooks/activity-<sessionId>.log via PostToolUse hook (no self-check line needed). See AGENTS.md "汇报纪律" for full discipline.'
    Exit-Pass $ctx
}

Exit-Pass
