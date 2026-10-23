# Bundled sounds: sources and licence

All sounds in `block/` are CC0 1.0 (public domain) files from Kenney's audio packs (https://kenney.nl).
Licence: CC0 1.0. Packs fetched on 2026-10-21. Each pack's own `License.txt` says "Creative Commons Zero, CC0" (http://creativecommons.org/publicdomain/zero/1.0/),
so they ship with no attribution and no restrictions. Credit to Kenney is welcome but not required.

Each file was trimmed of leading and trailing silence, given a 2 ms fade-in and a short fade-out (up to 30 ms) so it
does not click, converted to 16-bit 48 kHz mono WAV (shorter than 1.5 s), and level-matched to the same RMS
(about -18 dBFS) with a soft limiter keeping peaks at or below -3 dBFS. The file name is the cue name; to swap one,
replace the file and update its row here. A test and `scripts/test-release.sh` check that every file is listed below
with CC0 and that every cue has a file.

| File | Source pack | Original file | Licence | URL |
|---|---|---|---|---|
| `block/peek.wav` | Kenney, Interface Sounds | `maximize_007.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/open.wav` | Kenney, Interface Sounds | `open_002.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/close.wav` | Kenney, Interface Sounds | `close_002.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/hover.wav` | Kenney, UI Audio | `rollover3.ogg` | CC0 | https://kenney.nl/assets/ui-audio |
| `block/boop.wav` | Kenney, Interface Sounds | `bong_001.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/annoyed.wav` | Kenney, Interface Sounds | `error_001.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/dizzy.wav` | Kenney, Digital Audio | `phaserDown3.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/greet.wav` | Kenney, Digital Audio | `pepSound3.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/work.wav` | Kenney, Digital Audio | `powerUp6.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/think.wav` | Kenney, Interface Sounds | `select_003.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/search.wav` | Kenney, Interface Sounds | `scratch_004.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/approval.wav` | Kenney, Interface Sounds | `confirmation_004.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/question.wav` | Kenney, Interface Sounds | `confirmation_001.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/approve.wav` | Kenney, Interface Sounds | `confirmation_002.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/send.wav` | Kenney, Interface Sounds | `confirmation_003.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/finish.wav` | Kenney, Digital Audio | `threeTone2.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/error.wav` | Kenney, Interface Sounds | `error_007.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/rate.wav` | Kenney, Digital Audio | `lowThreeTone.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/love.wav` | Kenney, Digital Audio | `powerUp2.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/pop.wav` | Kenney, Interface Sounds | `pluck_001.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/proud.wav` | Kenney, Digital Audio | `powerUp7.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/wink.wav` | Kenney, Interface Sounds | `glass_002.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/yawn.wav` | Kenney, Digital Audio | `phaserDown1.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/sleep.wav` | Kenney, Digital Audio | `highDown.ogg` | CC0 | https://kenney.nl/assets/digital-audio |
| `block/tick.wav` | Kenney, Interface Sounds | `tick_004.ogg` | CC0 | https://kenney.nl/assets/interface-sounds |
| `block/switch.wav` | Kenney, UI Audio | `switch1.ogg` | CC0 | https://kenney.nl/assets/ui-audio |
