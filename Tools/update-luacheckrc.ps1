<#
.SYNOPSIS
    Regenerates AniMods\.luacheckrc.

.DESCRIPTION
    .luacheckrc is a build artifact, not a hand-maintained file. It is the
    concatenation of two things:

      1. The generated Blizzard globals list from Jayrgo/wow-luacheckrc
         (branch `mainline` = retail), which is itself parsed from
         Ketho/BlizzardInterfaceResources. ~44,000 entries, so luacheck knows
         every Blizzard global and its "undefined variable" warnings can be
         trusted rather than skimmed.

      2. Tools\luacheckrc.animods.lua -- our own additions.

    Edit Tools\luacheckrc.animods.lua. Edits made directly to .luacheckrc are
    lost the next time this runs.

    Re-run after a WoW patch adds API this addon starts using, or when a
    genuinely-existing global is being reported as undefined.
#>

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$overrides = Join-Path $PSScriptRoot "luacheckrc.animods.lua"
$target = Join-Path $root ".luacheckrc"
$url = "https://raw.githubusercontent.com/Jayrgo/wow-luacheckrc/mainline/.luacheckrc"

if (-not (Test-Path $overrides)) {
    throw "Missing $overrides -- cannot generate .luacheckrc without the AniMods section."
}

Write-Host "Downloading Blizzard globals list..." -ForegroundColor Cyan
Write-Host "  $url"

$temp = Join-Path $env:TEMP "animods-wow-luacheckrc.lua"
Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing

$base = Get-Content $temp -Raw
$mine = Get-Content $overrides -Raw

$header = @"
-- GENERATED FILE -- DO NOT EDIT.
--
-- Produced by Tools\update-luacheckrc.ps1 on $(Get-Date -Format 'yyyy-MM-dd').
-- Part 1 below is the Blizzard globals list from
-- https://github.com/Jayrgo/wow-luacheckrc (branch: mainline), which is
-- parsed from https://github.com/Ketho/BlizzardInterfaceResources.
-- Part 2, at the bottom, is Tools\luacheckrc.animods.lua verbatim.
--
-- To change linting behaviour, edit Tools\luacheckrc.animods.lua and re-run
-- Tools\update-luacheckrc.ps1. Edits made here are lost on regeneration.

"@

$separator = @"


-- ===========================================================================
-- Part 2: Tools\luacheckrc.animods.lua
-- ===========================================================================

"@

$out = $header + $base + $separator + $mine
Set-Content -Path $target -Value $out -Encoding utf8 -NoNewline

$lines = (Get-Content $target | Measure-Object -Line).Lines
Write-Host "Wrote $target ($lines lines)" -ForegroundColor Green
