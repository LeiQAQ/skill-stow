<#
.SYNOPSIS
  skill-stow - mount curated AI agent skill folders via Windows junctions.

.DESCRIPTION
  Source-as-truth skill linking. Reads a plain-text Stowfile, creates/removes
  junctions inside agent "target" folders that point back to "source" folders.
  Sources are NEVER modified. Junctions are preferred over symlinks because
  they need no admin rights and no Developer Mode.

  Requires PowerShell 5.1+ (Windows PowerShell or PowerShell 7+).

.EXAMPLE
  .\skill-stow.ps1 audit
  .\skill-stow.ps1 mount -All
  .\skill-stow.ps1 mount -Target workbuddy -Name brainstorming -DryRun
  .\skill-stow.ps1 unmount -All
  .\skill-stow.ps1 doctor
  .\skill-stow.ps1 list
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('audit', 'mount', 'unmount', 'doctor', 'list', 'help')]
    [string]$Command = 'help',

    [string]$Target,        # filter: target name (e.g. workbuddy)
    [string]$Name,          # filter: single skill name
    [string]$File,          # manifest path; default: Stowfile next to this script
    [switch]$All,           # apply to every mount in the manifest
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- manifest ---

function Expand-Home([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    if ($p -eq '~') { return $HOME }
    if ($p.StartsWith('~/') -or $p.StartsWith('~\')) { return Join-Path $HOME $p.Substring(2) }
    return $p
}

function Get-ScriptDir { Split-Path -Parent $PSCommandPath }

function Read-Stowfile([string]$path) {
    if (-not (Test-Path $path)) {
        Write-Error "Manifest not found: $path`nCreate a Stowfile (see Stowfile.example) or pass -File."
    }
    $manifest = @{ Targets = @{}; Sources = @{}; Mounts = New-Object System.Collections.ArrayList }
    $lineNo = 0
    foreach ($raw in Get-Content -Path $path) {
        $lineNo++
        $line = ($raw -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        $t = $line -split '\s+'
        switch ($t[0].ToLowerInvariant()) {
            'target' {
                if ($t.Count -lt 3) { Write-Error "Stowfile line ${lineNo}: 'target <name> <path>' expected" }
                $manifest.Targets[$t[1]] = (Expand-Home $t[2])
            }
            'source' {
                if ($t.Count -lt 3) { Write-Error "Stowfile line ${lineNo}: 'source <name> <path>' expected" }
                $manifest.Sources[$t[1]] = (Expand-Home $t[2])
            }
            'mount' {
                if ($t.Count -lt 4) { Write-Error "Stowfile line ${lineNo}: 'mount <target> <source> <skill>...' expected" }
                for ($i = 3; $i -lt $t.Count; $i++) {
                    [void]$manifest.Mounts.Add(@{ Target = $t[1]; Source = $t[2]; Skill = $t[$i]; Line = $lineNo })
                }
            }
            default { Write-Error "Stowfile line ${lineNo}: unknown directive '$($t[0])' (expected target/source/mount)" }
        }
    }
    # resolve references
    foreach ($m in $manifest.Mounts) {
        if (-not $manifest.Targets.ContainsKey($m.Target)) { Write-Error "mount line $($m.Line): unknown target '$($m.Target)'" }
        if (-not $manifest.Sources.ContainsKey($m.Source)) { Write-Error "mount line $($m.Line): unknown source '$($m.Source)'" }
    }
    return $manifest
}

# ------------------------------------------------------------------ linking ---

function Test-IsJunction([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return ($item.LinkType -eq 'Junction')
}

function Get-JunctionTarget([string]$path) {
    try { return [string](Get-Item -LiteralPath $path -Force).Target } catch { return '' }
}

function Normalize-Path([string]$p) {
    try { return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $p).Path) } catch { return $null }
}

# Remove a junction ONLY if it really is a junction whose stored target matches
# the expected source. Real directories are always refused.
function Remove-VerifiedJunction([string]$link, [string]$expectedSource, [switch]$DryRunSwitch) {
    if (-not (Test-Path -LiteralPath $link)) { return @{ Ok = $true; Status = 'MISSING' } }
    if (-not (Test-IsJunction $link)) {
        return @{ Ok = $false; Status = 'COLLISION' }
    }
    $actual = Get-JunctionTarget $link
    $expected = Normalize-Path $expectedSource
    $actualN = Normalize-Path $actual
    if (-not $expected -or -not $actualN -or
        ($actualN.TrimEnd('\') -ne $expected.TrimEnd('\'))) {
        return @{ Ok = $false; Status = 'DRIFTED'; Actual = $actual }
    }
    if ($DryRunSwitch) {
        Write-Host "[DRYRUN] would remove junction: $link"
    } else {
        [System.IO.Directory]::Delete($link, $false)
        Write-Host "[REMOVED] $link" -ForegroundColor Yellow
    }
    return @{ Ok = $true; Status = 'REMOVED' }
}

# --------------------------------------------------------------- selection ---

function Select-Mounts($manifest) {
    $mounts = $manifest.Mounts
    if ($Target) { $mounts = @($mounts | Where-Object { $_.Target -eq $Target }) }
    if ($Name)   { $mounts = @($mounts | Where-Object { $_.Skill -eq $Name }) }
    if (-not $All -and -not ($Target -or $Name)) {
        Write-Error "Refusing to act on everything implicitly. Pass -All, or filter with -Target / -Name."
    }
    return $mounts
}

# ---------------------------------------------------------------- commands ---

function Invoke-Audit($manifest) {
    $issues = 0
    $seen = @{}
    foreach ($m in $manifest.Mounts) {
        $tPath = $manifest.Targets[$m.Target]
        $sPath = $manifest.Sources[$m.Source]
        $link = Join-Path $tPath $m.Skill
        $src = Join-Path $sPath $m.Skill
        $linkN = Normalize-Path $tPath
        if ($linkN) { $seen[ (Join-Path $linkN $m.Skill).ToLowerInvariant() ] = $true }
        $label = "$($m.Target)/$($m.Skill)"
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Host ("{0,-10} {1}  (source missing: {2})" -f 'SRC-MISS', $label, $src) -ForegroundColor Red
            $issues++; continue
        }
        if (-not (Test-Path -LiteralPath $link)) {
            Write-Host ("{0,-10} {1}" -f 'MISSING', $label) -ForegroundColor Yellow
            $issues++; continue
        }
        if (Test-IsJunction $link) {
            $actual = Normalize-Path (Get-JunctionTarget $link)
            $expected = (Normalize-Path $src)
            if ($actual -and ($actual.TrimEnd('\') -eq $expected.TrimEnd('\'))) {
                Write-Host ("{0,-10} {1}" -f 'OK', $label) -ForegroundColor Green
            } else {
                Write-Host ("{0,-10} {1}  -> {2}" -f 'DRIFTED', $label, $actual) -ForegroundColor Red
                $issues++
            }
        } else {
            Write-Host ("{0,-10} {1}  (real directory occupies the link path)" -f 'COLLISION', $label) -ForegroundColor Red
            $issues++
        }
    }
    # extras: junctions present on disk but not in the manifest
    foreach ($tName in $manifest.Targets.Keys) {
        $tPath = $manifest.Targets[$tName]
        if (-not (Test-Path -LiteralPath $tPath)) { continue }
        foreach ($item in (Get-ChildItem -LiteralPath $tPath -Force -ErrorAction SilentlyContinue)) {
            $isReparse = ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink')
            if (-not $isReparse) { continue }
            if (-not $seen.ContainsKey($item.FullName.ToLowerInvariant())) {
                $tgtStr = ($item.Target | Select-Object -First 1)
                Write-Host ("{0,-10} {1}/{2}  ({3} -> {4})" -f 'EXTRA', $tName, $item.Name, $item.LinkType, $tgtStr) -ForegroundColor Yellow
                $issues++
            }
        }
    }
    if ($issues -eq 0) { Write-Host "`nAll clean." -ForegroundColor Green; return 0 }
    Write-Host "`n$issues issue(s) found." -ForegroundColor Red
    return 1
}

function Invoke-Mount($manifest) {
    $mounts = Select-Mounts $manifest
    $created = 0; $skipped = 0; $failed = 0
    foreach ($m in $mounts) {
        $link = Join-Path $manifest.Targets[$m.Target] $m.Skill
        $src = Join-Path $manifest.Sources[$m.Source] $m.Skill
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Host ("[SKIP]     source missing: {0}" -f $src) -ForegroundColor Red
            $failed++; continue
        }
        if (Test-Path -LiteralPath $link) {
            if (Test-IsJunction $link) {
                $actual = Normalize-Path (Get-JunctionTarget $link)
                $expected = Normalize-Path $src
                if ($actual -and ($actual.TrimEnd('\') -eq $expected.TrimEnd('\'))) { $skipped++; continue }
                Write-Host ("[DRIFTED]  {0} -> {1}; unmount first, then mount." -f $link, $actual) -ForegroundColor Red
                $failed++; continue
            }
            Write-Host ("[COLLISION] real directory in the way, refusing: {0}" -f $link) -ForegroundColor Red
            $failed++; continue
        }
        if ($DryRun) {
            Write-Host "[DRYRUN] would create junction: $link -> $src"
            $created++
        } else {
            try {
                New-Item -ItemType Junction -Path $link -Target $src -ErrorAction Stop | Out-Null
                Write-Host ("[MOUNTED]  {0} -> {1}" -f $link, $src) -ForegroundColor Green
                $created++
            } catch {
                Write-Host ("[FAILED]   {0}: {1}" -f $link, $_.Exception.Message) -ForegroundColor Red
                $failed++
            }
        }
    }
    Write-Host ("`ncreated: {0}  already-ok: {1}  failed: {2}" -f $created, $skipped, $failed)
    if ($failed -gt 0) { return 1 } else { return 0 }
}

function Invoke-Unmount($manifest) {
    $mounts = Select-Mounts $manifest
    $removed = 0; $failed = 0
    # longest-first so that overlapping filters behave predictably
    foreach ($m in $mounts) {
        $link = Join-Path $manifest.Targets[$m.Target] $m.Skill
        $src = Join-Path $manifest.Sources[$m.Source] $m.Skill
        $r = Remove-VerifiedJunction -link $link -expectedSource $src -DryRunSwitch:$DryRun
        if (-not $r.Ok) {
            if ($r.Status -eq 'COLLISION') {
                Write-Host ("[REFUSED]  {0} is a real directory; skill-stow never deletes real directories." -f $link) -ForegroundColor Red
            } elseif ($r.Status -eq 'DRIFTED') {
                Write-Host ("[REFUSED]  {0} points to '{1}', not the manifest source; not touching it." -f $link, $r.Actual) -ForegroundColor Red
            } elseif ($r.Status -eq 'MISSING') {
                Write-Host ("[ABSENT]   {0} (nothing to remove)" -f $link)
            }
            if ($r.Status -ne 'MISSING') { $failed++ }
        } elseif ($r.Status -eq 'REMOVED') {
            $removed++
        }
    }
    Write-Host ("`nremoved: {0}  refused: {1}" -f $removed, $failed)
    if ($failed -gt 0) { return 1 } else { return 0 }
}

function Invoke-Doctor($manifest) {
    $bad = 0
    foreach ($tName in $manifest.Targets.Keys) {
        $tPath = $manifest.Targets[$tName]
        if (-not (Test-Path -LiteralPath $tPath)) {
            Write-Host ("[WARN] target '{0}' does not exist: {1}" -f $tName, $tPath) -ForegroundColor Yellow
            $bad++
        }
    }
    foreach ($sName in $manifest.Sources.Keys) {
        if (-not (Test-Path -LiteralPath $manifest.Sources[$sName])) {
            Write-Host ("[ERR] source '{0}' does not exist: {1}" -f $sName, $manifest.Sources[$sName]) -ForegroundColor Red
            $bad++
        }
    }
    # broken links inside targets (point at anything that no longer exists)
    foreach ($tName in $manifest.Targets.Keys) {
        $tPath = $manifest.Targets[$tName]
        if (-not (Test-Path -LiteralPath $tPath)) { continue }
        foreach ($item in (Get-ChildItem -LiteralPath $tPath -Force -ErrorAction SilentlyContinue)) {
            if ($item.LinkType -ne 'Junction') { continue }
            $tgt = [string]$item.Target
            if ($tgt -and -not (Test-Path -LiteralPath $tgt)) {
                Write-Host ("[BROKEN]  {0}\{1} -> {2}" -f $tName, $item.Name, $tgt) -ForegroundColor Red
                $bad++
            }
        }
    }
    if ($bad -eq 0) { Write-Host "`nNo problems found." -ForegroundColor Green; return 0 }
    Write-Host "`n$bad problem(s)." -ForegroundColor Red
    return 1
}

function Invoke-List($manifest) {
    foreach ($m in $manifest.Mounts) {
        $link = Join-Path $manifest.Targets[$m.Target] $m.Skill
        $status = 'MISSING'
        if (Test-IsJunction $link) { $status = 'JUNCTION' }
        elseif (Test-Path -LiteralPath $link) { $status = 'COLLISION' }
        Write-Host ("{0,-12} {1,-12} {2,-30} [{3}]" -f $m.Target, $m.Source, $m.Skill, $status)
    }
    Write-Host ("`ntargets: {0}   sources: {1}   mounts: {2}" -f $manifest.Targets.Count, $manifest.Sources.Count, $manifest.Mounts.Count)
}

function Show-Help {
    Write-Host @"
skill-stow - junction-based skill mounting, source-as-truth.

Usage:
  skill-stow.ps1 audit                         compare manifest vs disk
  skill-stow.ps1 mount   [-All | -Target t -Name s] [-DryRun]
  skill-stow.ps1 unmount [-All | -Target t -Name s] [-DryRun]
  skill-stow.ps1 doctor                        find broken links / bad paths
  skill-stow.ps1 list                          show mounts with status

Options:
  -File <path>   manifest path (default: Stowfile next to this script)
  -DryRun        print actions without executing
"@
}

# -------------------------------------------------------------------- main ---

if (-not $File) { $File = Join-Path (Get-ScriptDir) 'Stowfile' }
$manifest = Read-Stowfile $File

switch ($Command) {
    'audit'   { exit (Invoke-Audit $manifest) }
    'mount'   { exit (Invoke-Mount $manifest) }
    'unmount' { exit (Invoke-Unmount $manifest) }
    'doctor'  { exit (Invoke-Doctor $manifest) }
    'list'    { Invoke-List $manifest; exit 0 }
    default   { Show-Help; exit 0 }
}
