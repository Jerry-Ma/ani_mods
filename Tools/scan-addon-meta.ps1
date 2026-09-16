<#
.SYNOPSIS
    Extracts each addon's dominant accent colour from its own icon art.

.DESCRIPTION
    WoW's Lua API cannot sample a texture -- there is no pixel access of any
    kind at runtime -- so PluginButtons cannot look at an addon's icon and ask
    what colour it is. It does not have to: the icons are image files sitting on
    disk, and this reads them where pixel access does exist. Sample at build
    time, ship the table.

    Emits a Lua table for Modules/PluginButtons.lua's ADDON_ACCENTS.

    WHAT "DOMINANT" MEANS HERE. Not the most common colour -- that is the
    background, which on an addon icon is almost always near-black, near-white
    or transparent. What identifies an icon is its most saturated mass: the cyan
    in Northern Sky's, the orange in AniMods'. So pixels are weighted by
    saturation and binned by HUE rather than by exact RGB, which keeps a
    gradient or an anti-aliased edge from splitting one colour into fifty
    near-misses that individually lose to the background.

    FORMATS. PNG and TGA are read directly. BLP -- Blizzard's own format, which
    a few addons use -- is not readable by System.Drawing and is skipped and
    reported, rather than guessed at.

.PARAMETER AddOnsPath
    The AddOns folder. Defaults to two levels above this script.

.PARAMETER MinSaturation
    Pixels below this saturation are treated as neutral and ignored entirely.

.EXAMPLE
    .\scan-addon-colors.ps1 | Set-Clipboard
#>
[CmdletBinding()]
param(
    [string] $AddOnsPath = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [double] $MinSaturation = 0.25,
    [double] $MinValue = 0.20
)

Add-Type -AssemblyName System.Drawing

# Icons live in a handful of conventional places. The TOC's own IconTexture is
# the authoritative one when it is there, since that is the icon the game itself
# shows for the addon.
function Get-IconCandidate {
    param([System.IO.DirectoryInfo] $AddonDir)

    $toc = Get-ChildItem -Path $AddonDir.FullName -Filter "*.toc" -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($toc) {
        $line = Select-String -Path $toc.FullName -Pattern '^##\s*IconTexture\s*:\s*(.+)$' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($line) {
            # Interface\AddOns\Foo\Media\icon -> Media\icon, relative to the addon.
            $raw = $line.Matches[0].Groups[1].Value.Trim()
            $rel = $raw -replace '^[Ii]nterface[\\/][Aa]dd[Oo]ns[\\/][^\\/]+[\\/]', ''
            $rel = $rel -replace '/', '\'
            foreach ($ext in @('', '.png', '.tga', '.blp')) {
                $path = Join-Path $AddonDir.FullName ($rel + $ext)
                if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
            }
        }
    }

    foreach ($pattern in @('icon.png', 'icon.tga', 'logo.png', 'logo.tga', 'Avatar.png')) {
        $hit = Get-ChildItem -Path $AddonDir.FullName -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    # The minimap button's own art, which for our purpose IS the addon's icon --
    # it is the thing the player associates with it. LibDBIcon takes it from the
    # LDB object's `icon` field, so the path is written literally in the addon's
    # source. Only files named like an icon are accepted: an addon references
    # dozens of textures and most of them are borders and bar fills.
    $hits = Select-String -Path (Join-Path $AddonDir.FullName '*.lua') `
        -Pattern '"(Interface[\\/]+AddOns[\\/]+[^"]+\.(?:tga|png))"' -AllMatches -ErrorAction SilentlyContinue
    foreach ($hit in $hits) {
        foreach ($m in $hit.Matches) {
            $raw = $m.Groups[1].Value
            if ($raw -notmatch '(?i)(icon|logo|minimap)') { continue }
            $rel = $raw -replace '^[Ii]nterface[\\/]+[Aa]dd[Oo]ns[\\/]+[^\\/]+[\\/]+', ''
            $rel = $rel -replace '/', '\'
            $path = Join-Path $AddonDir.FullName $rel
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        }
    }
    return $null
}

function Get-DominantHex {
    param([string] $Path, [double] $MinSaturation, [double] $MinValue)

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.blp') { return $null }   # not readable here; reported by the caller

    try { $bitmap = [System.Drawing.Bitmap]::FromFile($Path) } catch { return $null }

    try {
        # 24 hue bins of 15 degrees. Fine enough to keep cyan and blue apart,
        # coarse enough that a gradient stays one colour.
        $bins = New-Object 'double[]' 24
        $sumR = New-Object 'double[]' 24
        $sumG = New-Object 'double[]' 24
        $sumB = New-Object 'double[]' 24

        # Big icons are sampled on a grid rather than read whole: a 512px icon is
        # a quarter-million pixels and the answer does not change.
        $stepX = [Math]::Max(1, [int]($bitmap.Width / 128))
        $stepY = [Math]::Max(1, [int]($bitmap.Height / 128))

        for ($y = 0; $y -lt $bitmap.Height; $y += $stepY) {
            for ($x = 0; $x -lt $bitmap.Width; $x += $stepX) {
                $c = $bitmap.GetPixel($x, $y)
                if ($c.A -lt 128) { continue }          # transparent: not part of the art

                $sat = $c.GetSaturation()
                $val = $c.GetBrightness()
                if ($sat -lt $MinSaturation) { continue }   # grey: background or outline
                if ($val -lt $MinValue) { continue }        # near-black: shadow

                # Weighted by saturation, so a vivid core outweighs a washed-out
                # halo of the same hue.
                $bin = [int]([Math]::Floor($c.GetHue() / 15.0)) % 24
                $bins[$bin] += $sat
                $sumR[$bin] += $c.R * $sat
                $sumG[$bin] += $c.G * $sat
                $sumB[$bin] += $c.B * $sat
            }
        }

        $best = -1
        $bestWeight = 0.0
        for ($i = 0; $i -lt 24; $i++) {
            if ($bins[$i] -gt $bestWeight) { $bestWeight = $bins[$i]; $best = $i }
        }
        if ($best -lt 0) { return $null }   # no saturated pixels at all: a grey icon

        $r = [int][Math]::Round($sumR[$best] / $bins[$best])
        $g = [int][Math]::Round($sumG[$best] / $bins[$best])
        $b = [int][Math]::Round($sumB[$best] / $bins[$best])
        return ('{0:x2}{1:x2}{2:x2}' -f $r, $g, $b)
    }
    finally {
        $bitmap.Dispose()
    }
}

# A colour the addon NAMES as its own, read out of its source.
#
# Deliberately narrow. Grepping for colour literals returns hundreds per addon
# -- every bar fill, border and class colour -- and picking among them is
# guessing. Only an assignment whose VARIABLE NAME says the colour is the
# addon's own identity counts: accent, brand, theme, primary. That misses
# addons which never name such a thing, which is the correct outcome; a wrong
# colour is worse than no colour, because no colour falls through to a hue that
# at least stays put.
function Get-DeclaredHex {
    param([System.IO.DirectoryInfo] $AddonDir)

    $files = Get-ChildItem -Path $AddonDir.FullName -Filter '*.lua' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 400
    if (-not $files) { return $null }

    $namePattern = '(?i)\b\w*(accent|brand|theme|primary)\w*(color|colour)\w*\b'

    foreach ($file in $files) {
        $hits = Select-String -Path $file.FullName -Pattern $namePattern -ErrorAction SilentlyContinue
        foreach ($hit in $hits) {
            $line = $hit.Line

            # "ff33ccff" or "33ccff", as a quoted hex string.
            $m = [regex]::Match($line, '"(?:\|c)?(?:[0-9a-fA-F]{2})?([0-9a-fA-F]{6})"')
            if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }

            # { r = 0.2, g = 0.8, b = 0.9 } or { 0.2, 0.8, 0.9 } -- three
            # fractions on one line, which is how a Lua colour is written.
            $nums = [regex]::Matches($line, '(?<![\w.])(0?\.\d+|0|1(?:\.0+)?)(?![\w.])')
            if ($nums.Count -ge 3) {
                $vals = @($nums[0].Value, $nums[1].Value, $nums[2].Value) |
                    ForEach-Object { [double]$_ }
                if (($vals | Where-Object { $_ -gt 1 }).Count -eq 0) {
                    return ('{0:x2}{1:x2}{2:x2}' -f
                        [int][Math]::Round($vals[0] * 255),
                        [int][Math]::Round($vals[1] * 255),
                        [int][Math]::Round($vals[2] * 255))
                }
            }
        }
    }
    return $null
}

# The slash command an addon registers for itself, which makes a far better
# widget label than any abbreviation: "/bw" and "/ns" are what you would type,
# so they are already the name you know it by.
#
# An addon registers several, and most of them are not its identity -- MRT
# registers /rl for reload and /key for keystones alongside /mrt. A command
# counts only if its letters are a SUBSEQUENCE of the addon's name: /bw fits
# BigWigs, /ns fits NorthernSkyRaidTools, /ksl fits KeystoneLoot, while /rl does
# not fit MRT and /key does not fit Details. Shortest of the survivors wins,
# because that is the alias the author made for exactly this purpose.
function Test-Subsequence {
    param([string] $Needle, [string] $Haystack)
    $i = 0
    foreach ($ch in $Haystack.ToCharArray()) {
        if ($i -lt $Needle.Length -and $ch -eq $Needle[$i]) { $i++ }
    }
    return $i -eq $Needle.Length
}

function Get-SlashCommand {
    param([System.IO.DirectoryInfo] $AddonDir)

    $name = ($AddonDir.Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    if (-not $name) { return $null }

    $files = Get-ChildItem -Path $AddonDir.FullName -Filter '*.lua' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 400
    if (-not $files) { return $null }

    $found = @{}
    foreach ($file in $files) {
        $hits = Select-String -Path $file.FullName -Pattern 'SLASH_\w+\d+\s*=\s*"(/[^"]+)"' -AllMatches -ErrorAction SilentlyContinue
        foreach ($hit in $hits) {
            foreach ($m in $hit.Matches) {
                $cmd = $m.Groups[1].Value.ToLowerInvariant()
                if ($cmd -match '^/[a-z0-9]+$') { $found[$cmd] = $true }
            }
        }
    }

    $best = $null
    foreach ($cmd in $found.Keys) {
        $letters = $cmd.Substring(1)
        # Must start where the name starts. "rt" is a subsequence of "mrt" and
        # would beat "/mrt" on length, but nobody reads /rt as MRT.
        if ($letters[0] -ne $name[0]) { continue }
        if (-not (Test-Subsequence -Needle $letters -Haystack $name)) { continue }
        if (-not $best -or $cmd.Length -lt $best.Length) { $best = $cmd }
    }
    return $best
}

$results = @()
$slashes = @()
$skippedBlp = @()
$noIcon = @()

Get-ChildItem -Path $AddOnsPath -Directory | Sort-Object Name | ForEach-Object {
    $addon = $_
    $hex = $null
    $from = $null

    # The art first: it is what the player actually associates with the addon,
    # where a named constant is only what its author called something.
    $icon = Get-IconCandidate -AddonDir $addon
    if ($icon) {
        if ([System.IO.Path]::GetExtension($icon).ToLowerInvariant() -eq '.blp') {
            $skippedBlp += $addon.Name
        } else {
            $hex = Get-DominantHex -Path $icon -MinSaturation $MinSaturation -MinValue $MinValue
            if ($hex) { $from = 'icon' }
        }
    } else {
        $noIcon += $addon.Name
    }

    if (-not $hex) {
        $hex = Get-DeclaredHex -AddonDir $addon
        if ($hex) { $from = 'source' }
    }

    # A near-black or near-white "theme colour" is a background, not a brand.
    # The source probe is the one that finds these -- an author calls the panel
    # backdrop themeColor as readily as the highlight -- and shipping one means
    # shipping a label nobody can read.
    if ($hex -and $from -eq 'source') {
        $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
        $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
        $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
        $luma = (0.299 * $r + 0.587 * $g + 0.114 * $b) / 255.0
        if ($luma -lt 0.18 -or $luma -gt 0.95) { $hex = $null }
    }

    if ($hex) {
        $results += [pscustomobject]@{ Addon = $addon.Name; Hex = $hex; From = $from }
    }

    $slash = Get-SlashCommand -AddonDir $addon
    if ($slash) {
        $slashes += [pscustomobject]@{ Addon = $addon.Name; Slash = $slash }
    }
}

Write-Output "-- Generated by Tools\scan-addon-colors.ps1 -- do not hand-edit."
Write-Output "-- Each value is the dominant saturated hue of that addon's own icon art."
Write-Output "local ADDON_ACCENTS = {"
foreach ($row in $results) {
    Write-Output ('    ["{0}"] = "{1}",{2}' -f $row.Addon, $row.Hex,
        $(if ($row.From -eq 'source') { '  -- named in its own source' } else { '' }))
}
Write-Output "}"

Write-Output ""
Write-Output "-- The slash command each addon registers for itself, picked as the"
Write-Output "-- shortest whose letters are a subsequence of the addon's name."
Write-Output "local ADDON_SLASH = {"
foreach ($row in $slashes) {
    Write-Output ('    ["{0}"] = "{1}",' -f $row.Addon, $row.Slash)
}
Write-Output "}"

Write-Output ""
Write-Output ("-- {0} colours, {1} slash commands." -f $results.Count, $slashes.Count)
if ($skippedBlp.Count -gt 0) {
    Write-Output ("-- BLP icons, not readable here: {0}" -f ($skippedBlp -join ', '))
}
if ($noIcon.Count -gt 0) {
    Write-Output ("-- No icon found: {0}" -f ($noIcon.Count))
}
