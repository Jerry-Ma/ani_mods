# Regenerating the Cooldown Manager sound table

`Modules\CDMSounds.lua`'s `SOUNDS` table is generated, not typed. This is how,
and why it has to be done offline.

## Why offline

Resolving one `Enum.CooldownViewerSound` ordinal to something playable takes two
steps, and neither is available to an addon at runtime:

| Step | Where it lives | Reachable in Lua? |
|---|---|---|
| ordinal → `soundKitID` | `CooldownViewerSoundData`, a global in `Blizzard_CooldownViewer` | yes, but only once that addon is loaded |
| `soundKitID` → FileDataID | `SoundKitEntry.db2` | **no** — there is no API for this |

`PlaySound` takes a kit, `PlaySoundFile` takes a file, and nothing converts
between them. Watching instead of reading was tried and does not work either:
the settings dropdown does not preview on selection, and a real alert plays
entirely in C, so neither `PlaySound` nor `PlaySoundFile` ever sees it.

So the join is done here and the result shipped as integers. **No audio is
copied** — a FileDataID names a file the game already owns.

## The two sources

1. **Blizzard's mapping**, the enum-to-kit half, from Townlong Yak's mirror of
   the live UI source:

   ```
   https://www.townlong-yak.com/framexml/live/Blizzard_CooldownViewer/CooldownViewerSoundAlertData.lua
   ```

   Served as an HTML source viewer, so the values need extracting from the
   markup. One row per sound:

   ```
   { soundEnum = Enum.CooldownViewerSound.AnimalsCat, soundKitID = 316401, text = CDMSND_ANIMALS_CAT }, -- Cat
   ```

   The category comes from the enclosing `[Enum.CooldownViewerSoundCategory.X]`
   key; the label from the trailing comment.

2. **The kit-to-file half**, from wago.tools' DB2 export:

   ```
   https://wago.tools/db2/SoundKitEntry/csv
   ```

   About 37 MB, columns `ID,SoundKitID,FileDataID,Frequency,Volume,PlayerConditionID`.
   Stream it rather than loading it; only the rows whose `SoundKitID` is one of
   the 93 are wanted.

   A single kit can be checked without the whole file:
   `https://wago.tools/db2/SoundKitEntry/csv?filter[SoundKitID]=316493`

## What came out, as of 12.1.0 build 69933

- **93 sounds** across 7 categories: Animals 10, Devices 11, Impacts 10,
  Instruments 12, Short 26, War2 12, War3 12.
- Every kit resolved, **1:1** — no kit mapped to more than one file, none
  unresolved. That matters: a multi-file kit picks randomly, and a FileDataID
  would have captured only one of its sounds.
- `Enum.CooldownViewerSound` has a 94th entry, `TextToSpeech` (0). It has no
  soundKitID and is not a sound; it is not in the table.

## Two things to preserve when regenerating

- **The category belongs in the registered name.** Two labels repeat across
  categories — *Stove Pipe* (Devices and Short) and *Synth High* (Instruments
  and Short). LibSharedMedia refuses a name already taken rather than replacing
  it, so without the category the second of each pair silently never registers.
- **"Guiter"** is Blizzard's spelling in the Short category. Kept as-is so the
  name matches what the Cooldown Manager's own list shows.

## Verifying

LibSharedMedia validates a sound **only when the data is a string** — it checks
the file exists and ends in `.ogg` or `.mp3`. A number goes into its table
unchecked, so a wrong FileDataID registers happily and plays silence with
nothing reporting a problem. The module's **Test** button plays one directly;
use it after any regeneration.
