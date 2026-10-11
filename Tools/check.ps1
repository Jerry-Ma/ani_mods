<#
.SYNOPSIS
    Offline checks for AniMods. Run before committing.

.DESCRIPTION
    Four layers, in order, because each catches what the previous cannot:

    1. luac -p  -- a real Lua 5.1 parse of every file the .toc loads, in load
       order. WoW runs Lua 5.1; luacheck's own bundled runtime is 5.4 and its
       parser accepts a syntax superset, so this is the only step that will
       actually reject something 5.1 can't compile. It also cross-checks the
       .toc against the files on disk in both directions, which a rename can
       otherwise silently break.

    2. luacheck -- static analysis against the full Blizzard globals list
       (see Tools\update-luacheckrc.ps1). Typo'd or undefined globals,
       accidental global writes, unused and shadowed locals.

    3. lua-language-server --check -- type-aware diagnostics against the WoW
       API annotations shipped by the "WoW API" VS Code extension
       (Ketho/vscode-wow-api). This is the only layer that knows what WoW
       functions RETURN, so it is the only one that catches a possibly-nil
       value passed somewhere that can't take nil, a wrong argument type, or
       a call to an API that no longer exists. It found exactly that class of
       bug on its first run here.

       Uses the language server binary bundled with the sumneko.lua extension,
       so there is nothing extra to install; both extensions are discovered by
       glob rather than pinned, so a version bump doesn't break this.

    4. Deprecated API -- greps the source against Blizzard_Deprecated, which
       the annotations mirror. The three layers above all PASS a deprecated
       call: it exists, it is annotated, and it returns the right type. It
       just stops existing a patch or two later, silently.

    None of this runs the addon. A wrong event name, a nonexistent atlas, a
    loop that iterates zero times -- all pass clean. A /reload is still the
    real test; this only makes one worth doing.

    What none of it can catch is a GUESSED API name hidden behind an existence
    check. `if C_Thing.Fn then ... end` on a function that was never called
    that makes layer 3 blind -- it has plenty to say about a direct call to a
    name that is not in the annotations, and nothing at all about a boolean
    test. So: call Blizzard APIs directly and let a wrong name throw. Guard
    only what may genuinely be absent -- another addon, a load-on-demand
    frame, a value the game declines to give you.

.PARAMETER Fast
    Layer 1 only (Lua 5.1 parse). A quick gate while iterating.

.PARAMETER SkipTypes
    Layers 1 and 2 only. Use when the VS Code extensions aren't installed
    (layer 4 reads the deprecated list from the same extension).

.EXAMPLE
    .\Tools\check.ps1
#>

[CmdletBinding()]
param(
    [switch] $Fast,
    [switch] $SkipTypes
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$toc = Join-Path $root "AniMods.toc"
$failed = $false

if (-not (Test-Path $toc)) { throw "No AniMods.toc at $toc" }

# --- Layer 1: Lua 5.1 syntax ------------------------------------------------

if (-not (Get-Command luac -ErrorAction SilentlyContinue)) {
    Write-Host "Missing 'luac'. Install with: scoop install lua-for-windows" -ForegroundColor Yellow
    exit 2
}

# Parse the .toc the way the client does: skip blanks and ## directives, take
# the rest as paths relative to the addon root. This is what makes a file
# renamed on disk but not in the .toc (or vice versa) an error here rather
# than a silent no-load in game.
$files = Get-Content $toc | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") } |
    Where-Object { $_.ToLower().EndsWith(".lua") }

Write-Host "[1/4] Lua 5.1 syntax ($($files.Count) files from AniMods.toc)" -ForegroundColor Cyan

foreach ($rel in $files) {
    $path = Join-Path $root $rel
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

# A .lua on disk that the .toc never loads is dead weight at best, and a file
# renamed without updating the .toc at worst. Tools\ is excluded: it holds
# tooling and LuaLS stubs, none of which the game ever loads.
$onDisk = Get-ChildItem $root -Recurse -Filter *.lua |
    Where-Object { $_.FullName -notmatch '\\(Libs|Tools)\\' } |
    ForEach-Object { $_.FullName.Substring($root.Length + 1) }
foreach ($f in $onDisk) {
    if ($files -notcontains $f) {
        Write-Host "  ORPHAN   $f  (on disk, not in AniMods.toc)" -ForegroundColor Yellow
    }
}

if ($failed) { Write-Host "`nSyntax check failed." -ForegroundColor Red; exit 1 }
if ($Fast) { Write-Host "`nSyntax OK (-Fast: lint and types skipped)." -ForegroundColor Green; exit 0 }

# --- Layer 2: luacheck ------------------------------------------------------

if (-not (Get-Command luacheck -ErrorAction SilentlyContinue)) {
    Write-Host "Missing 'luacheck'. Install with: scoop install luacheck" -ForegroundColor Yellow
    exit 2
}
if (-not (Test-Path (Join-Path $root ".luacheckrc"))) {
    Write-Host "No .luacheckrc. Generate it with: .\Tools\update-luacheckrc.ps1" -ForegroundColor Yellow
    exit 2
}

Write-Host "`n[2/4] luacheck" -ForegroundColor Cyan
Push-Location $root
try { & luacheck . --codes; $lintExit = $LASTEXITCODE } finally { Pop-Location }
if ($lintExit -ne 0) { $failed = $true }

if ($SkipTypes) {
    if ($failed) { Write-Host "`nFindings above." -ForegroundColor Yellow; exit 1 }
    Write-Host "`nPassed (-SkipTypes: type check skipped)." -ForegroundColor Green
    exit 0
}

# --- Layer 3: lua-language-server -------------------------------------------

# Both extensions are found by glob and the newest match wins, so upgrading
# either doesn't need an edit here. VS Code and Insiders are both searched.
function Find-Newest($pattern) {
    Get-Item $pattern -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
}

$lsp = Find-Newest "$env:USERPROFILE\.vscode*\extensions\sumneko.lua-*\server\bin\lua-language-server.exe"
$annotations = Find-Newest "$env:USERPROFILE\.vscode*\extensions\ketho.wow-api-*\Annotations"

if (-not $lsp -or -not $annotations) {
    Write-Host "`n[3/4] Skipped (and 4/4): install the VS Code extensions 'Lua' (sumneko.lua) and 'WoW API' (ketho.wow-api)." -ForegroundColor Yellow
    if ($failed) { exit 1 }
    exit 0
}

Write-Host "`n[3/4] lua-language-server ($(Split-Path -Leaf (Split-Path -Parent $annotations.FullName)))" -ForegroundColor Cyan

# --configpath replaces every other config source, so the committed
# .luarc.json is merged here rather than relied on -- with relative paths made
# absolute, since this temp config does not sit in the workspace.
$luarc = Get-Content (Join-Path $root ".luarc.json") -Raw | ConvertFrom-Json
$library = @($annotations.FullName)
foreach ($lib in $luarc.'workspace.library') {
    $library += (Join-Path $root $lib)
}

$cfg = [ordered]@{
    'runtime.version'           = $luarc.'runtime.version'
    'workspace.library'         = $library
    'workspace.ignoreDir'       = $luarc.'workspace.ignoreDir'
    'workspace.checkThirdParty' = $false
    'diagnostics.globals'       = $luarc.'diagnostics.globals'
    'diagnostics.disable'       = $luarc.'diagnostics.disable'
}

$work = Join-Path ([IO.Path]::GetTempPath()) "animods-luals"
New-Item -ItemType Directory -Force $work | Out-Null
$cfgPath = Join-Path $work "config.json"
$cfg | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding utf8

& $lsp.FullName --check="$root" --configpath="$cfgPath" --logpath="$work\log" `
    --checklevel=Warning --check_format=pretty
if ($LASTEXITCODE -ne 0) { $failed = $true }

# --- Layer 4: deprecated API ------------------------------------------------
#
# The three layers above all accept a deprecated call: it exists, it is
# annotated, and it returns the right type. What makes it worth catching is
# that Blizzard removes these a patch or two after announcing them, and the
# removal is silent at the call site.
#
# The list is the same Blizzard_Deprecated the game ships, as the annotations
# mirror it. Note what that means: the annotations lag the live build (0.22.3
# targets 12.0.1), so a deprecation from a newer patch is NOT in here. Check
# raw.githubusercontent.com/Gethe/wow-ui-source/live/Interface/AddOns/
# Blizzard_Deprecated/Mainline/ when bumping game versions.
#
# Comments match too. That is deliberate: a comment naming a dead API is
# documentation that will mislead the next reader.
Write-Host "`n[4/4] Deprecated API" -ForegroundColor Cyan

$deprecated = Get-ChildItem -Path $annotations.FullName -Recurse -Filter "Deprecated_*" |
    Select-String -Pattern "^function ([A-Za-z_][\w\.]*)\(" |
    ForEach-Object { $_.Matches[0].Groups[1].Value } |
    Sort-Object -Unique

$sources = Get-ChildItem -Path $root -Recurse -Filter "*.lua" |
    Where-Object { $_.FullName -notmatch "\\Libs\\" }

$found = $false
foreach ($name in $deprecated) {
    # Not preceded by a word character or a dot, so AniMods' own helper of the
    # same name and any C_Namespace.Member spelling are both left alone.
    $hits = $sources | Select-String -Pattern "(?<![\w\.])$([regex]::Escape($name))\s*\("
    foreach ($hit in $hits) {
        $found = $true
        Write-Host ("  {0}:{1}  {2}" -f $hit.Filename, $hit.LineNumber, $name) -ForegroundColor Red
    }
}

if ($found) {
    $failed = $true
} else {
    Write-Host "  none ($($deprecated.Count) symbols checked)"
}

if ($failed) { Write-Host "`nFindings above." -ForegroundColor Yellow; exit 1 }
Write-Host "`nAll checks passed." -ForegroundColor Green
