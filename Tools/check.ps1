<#
.SYNOPSIS
    Offline checks for AniMods. Run before committing.

.DESCRIPTION
    Two layers, in order, because they catch different things:

    1. luac -p  -- a real Lua 5.1 parse of every file the .toc loads, in load
       order. WoW runs Lua 5.1; luacheck's own bundled runtime is 5.4 and its
       parser accepts a syntax superset, so this is the only step that will
       actually reject something 5.1 can't compile. It also confirms the .toc
       and the files on disk agree, which a rename can silently break.

    2. luacheck -- static analysis against the full Blizzard globals list
       (see Tools\update-luacheckrc.ps1). Catches typo'd/undefined globals,
       accidental global writes, unused and shadowed locals.

    Neither runs the addon. They cannot catch a wrong event name, a nonexistent
    atlas, a loop that iterates zero times, or a value used at the wrong type.
    A /reload is still the real test -- this only makes it worth doing.

.PARAMETER SkipLint
    Run only the Lua 5.1 parse. Useful as a fast pre-save gate.

.EXAMPLE
    .\Tools\check.ps1
#>

[CmdletBinding()]
param(
    [switch] $SkipLint
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$toc = Join-Path $root "AniMods.toc"
$failed = $false

# --- Layer 1: Lua 5.1 syntax ------------------------------------------------

foreach ($tool in @("luac", "luacheck")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "Missing '$tool'. Install with: scoop install lua-for-windows luacheck" -ForegroundColor Yellow
        exit 2
    }
}

if (-not (Test-Path $toc)) { throw "No AniMods.toc at $toc" }

# Parse the .toc the way the client does: skip blank lines and ## directives,
# take everything else as a file path relative to the addon root. This is what
# makes a file renamed on disk but not in the .toc (or vice versa) an error
# here rather than a silent no-load in game.
$files = Get-Content $toc | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") } |
    Where-Object { $_.ToLower().EndsWith(".lua") }

Write-Host "Lua 5.1 syntax ($($files.Count) files from AniMods.toc)" -ForegroundColor Cyan

foreach ($rel in $files) {
    $path = Join-Path $root ($rel -replace '\\', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $path)) {
        Write-Host "  MISSING  $rel  (listed in AniMods.toc, not on disk)" -ForegroundColor Red
        $failed = $true
        continue
    }
    $out = & luac -p $path 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL     $rel" -ForegroundColor Red
        Write-Host $out.Trim()
        $failed = $true
    } else {
        Write-Host "  ok       $rel" -ForegroundColor DarkGray
    }
}

# Any .lua on disk that the .toc never loads is dead weight at best and a file
# that was renamed without updating the .toc at worst.
$onDisk = Get-ChildItem $root -Recurse -Filter *.lua |
    Where-Object { $_.FullName -notmatch '\\(Libs|Tools)\\' } |
    ForEach-Object { $_.FullName.Substring($root.Length + 1) }
$loaded = $files | ForEach-Object { $_ -replace '/', '\' }
foreach ($f in $onDisk) {
    if ($loaded -notcontains $f) {
        Write-Host "  ORPHAN   $f  (on disk, not in AniMods.toc)" -ForegroundColor Yellow
    }
}

if ($failed) {
    Write-Host "`nSyntax check failed." -ForegroundColor Red
    exit 1
}

if ($SkipLint) { Write-Host "`nSyntax OK (lint skipped)." -ForegroundColor Green; exit 0 }

# --- Layer 2: luacheck ------------------------------------------------------

Write-Host "`nluacheck" -ForegroundColor Cyan
Push-Location $root
try {
    & luacheck . --codes
    $lintExit = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($lintExit -ne 0) {
    Write-Host "`nLint reported findings." -ForegroundColor Yellow
    exit 1
}

Write-Host "`nAll checks passed." -ForegroundColor Green
