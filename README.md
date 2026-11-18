# f65: AULA F65 control on macOS

Reverse-engineered from the official Windows driver (`AULA F65 driver.exe`, Inno Setup →
MFC app, device class `CDev3632`). Every write first saves a backup to `backups/`.

```bash
swiftc -O -o f65 f65.swift
./f65 led                          # show current lighting
./f65 led effect neon              # fixed breathing rainbow flash-away raindrops rainbow-wheel ripples
                                   # stars shadow snake neon reaction sine-wave scanning windmill
                                   # waterfall blossom storm   (or 1–18)
./f65 led brightness 3             # 0–4
./f65 led speed 2                  # 0–4
./f65 led color blue               # red green blue yellow magenta cyan white rainbow (or 0–7)
./f65 palette                      # show the 7 palette colours
./f65 palette blue #6a00ff         # redefine palette colour "blue" (any #rrggbb)
./f65 palette reset                # factory palette
./f65 remap capslock lctrl         # base layer
./f65 remap f play --fn            # Fn layer: Fn+F = play/pause
./f65 remap rcmd none              # disable a key
./f65 keys                         # readable key map (base + Fn layer)
./f65 restore backups/<file>.txt   # put lighting + both key layers back
./f65 probe | diff 44 | read 4a    # low-level reading
```
Wake the keyboard (press a key) if a command says it's waiting.

## Lighting block (cmd 04/44, 128 bytes) — confirmed by testing
| Offset | Meaning |
|---|---|
| `0x0a` | Current effect (1 = Fixed on, 11 = Neon stream; order = driver's effect list) |
| `0x12` | **Side lights** effect: 0 Off, 1 Rainbow flow, 2 Colour cycle, 3 Solid, 4 Breathing (Fn + Right Shift steps 1→2→3→4→0) |
| `0x13` | Side lights palette colour 0–6, 7 = multicolour |
| `0x14` | Side lights brightness 0–4 |
| `0x15` | Side lights speed 0–4 |

The side lights can only be changed by saving this block, and the keyboard turns **all** its lights off for a moment
whenever it stores the block (keys and side strips). They are not part of the live per-key frame: lighting all 58
slots without a key over 2.4G left the side strips unchanged (tested on the F65).
| `0x38 + 2·effect` | Brightness 0–4 for that effect |
| `0x39 + 2·effect` | High nibble: speed 0–4 · low nibble: palette colour 0–6, 7 = multicolour |
| `0x7e–0x7f` | `5a a5` end marker |
## Colour palette (cmd 09/49, 490 bytes) — confirmed
23 groups × 7 colours × (R,G,B) + 7-byte trailer. Factory: red, green, blue, yellow, magenta,
cyan, white. The side light strip also uses it. It is **not** a per-key colour table: effects 19–21
are not custom per-key modes (21 = key lights off, status lights only).

## Device
| Mode | VID:PID |
|---|---|
| 2.4G receiver | `3554:FA09` |
| USB cable | `258A:010C` |

Control interface: vendor usage page `0xFF02`, report ID `0x13`, 20 bytes each way
(output report sent with SetReport, replies arrive as input reports).

## Packet
```
[0] 0x13   [1] cmd   [2] packet count   [3] packet index
[4] (sub << 4) | data length (≤14)   [5..18] data   [19] sum(bytes 0..18) & 0xFF
```
A reply with bit 7 of `cmd` set is a NAK. Multi-packet replies come back as `count` packets.
Over 2.4G some packets are dropped, so the tool retries and merges packets by index.

## Commands (✅ = confirmed working on your keyboard)
| Write | Read | What | Size |
|---|---|---|---|
| — | `07` ✅ | Is the keyboard connected to the receiver (1 = yes) | 1 |
| `01` | `41` ✅ | Key matrix; sub 0 = base layer, sub 1 = Fn layer | 504 |
| `02` | `42` | Game-mode settings | no reply yet |
| `03` | `43` ✅ | Macro memory (currently empty) | 512 |
| `04` | `44` ✅ | Lighting settings (ends in `5a a5`) | 128 |
| `06` | — | Factory reset | — |
| `09` | `49` ✅ | 7-colour palette (per effect) | 490 |
| `0A` | `4A` ✅ | Onboard settings (`64 10`: possibly battery 100% + flags) | 2 |
| `0B` | — | Screen parameters (not used on the F65) | — |

The keyboard also sends unprompted `0A` status reports when it wakes up (e.g. `05 64 10 00`).

## Key matrix format
4 bytes per slot, column-major, 6 rows per column (21 columns).
| Type | Meaning | Example |
|---|---|---|
| `00 mods 00 usage` | Normal key + modifier bitmask | `00 04 00 2b` = Alt+Tab |
| `02 00 hi lo` | Media/consumer key | `02 00 00 e2` = Mute |
| `07 00 00 n` | Lighting function n | Fn+Q etc. |
| `08 a b c` | Connection/system (BT channel, 2.4G, …) | |
| `0d 00 00 00` | Fn key itself | |

## What the official driver can change (from its UI)
- **Lighting**: 20 effects (Fixed, Respire, Rainbow, Flash away, Raindrops, Rainbow wheel,
  Ripples, Stars, Shadow, Retro snake, Neon stream, Reaction, Sine wave, Scanning, Windmill,
  Waterfall, Blossoming, Storm, Self-define, Off), brightness 0–4, speed 0–4, direction,
  colour / random colour, per-key custom colours.
- **Music mode**: lighting that follows system audio (10 modes, done by the app streaming data).
- **Key remap**: any key on base and Fn layers → key, combo, media key, mouse button,
  Windows command, macro, or disabled.
- **Macros**: recorded key/mouse sequences with delays and loop modes.
- **Game mode**: Win-key lock and similar.
- **Sleep timer** (wireless), **debounce**, **battery**, firmware version, factory reset.

## Not done yet
- Per-key colours can't be **stored** on the F65 (effect 21 only blanks the keys), but they work as
  **live lighting** over the cable: see "Live per-key lighting" below.
- Macros, game mode, sleep timer, debounce, factory reset:
  readable or located, but writes are still blocked in the code.
- Lighting bytes `0x00–0x37` (probably direction, sleep and global flags) aren't decoded yet.
- Firmware update: will not be implemented (risk of bricking).

## Wired mode (USB cable, 258A:010C) — `wired.swift`, read-only
Driver class `CDevG5KB`. 520-byte feature report, ID 6:
`06 | cmd | sub | 00 | page count | page index | len lo | len hi | ≤512 data bytes`.
Read = send the header with `cmd | 0x80` (SetReport), then GetReport. Write cmds: 03 key matrix,
04 LED, 05 macro, 06 game, 0A palette, 0B ?, 11 factory reset.
Reads return the **same** lighting block, palette and key map as 2.4G, so the cable is just
another way to reach the same storage. Unknown commands (0B–12) return windows onto other blocks.
```bash
swiftc -O -o wired wired.swift
./wired               # LED, palette, key map
./wired 04 128 -v     # one block: <cmd> <length> [sub]
```

## Live per-key lighting (cable only) — confirmed
Method from [aula-f75-mac-driver](https://github.com/Itzadetunji/aula-f75-mac-driver) (same chip).
One feature report per frame: `06 08 00 00 01 00 7a 01` + 126 × (R,G,B), slot = column×6 + row
(same numbering as the key map). Send ~20 frames/s; faster starves key scanning. The keyboard goes
back to its saved effect about a second after frames stop. Nothing is written to its memory.
```bash
./wired live test 15                               # row colours, 15 s
./wired live all purple                            # until Ctrl-C
./wired live keys w=red a=red s=red d=red rest=off # until Ctrl-C (add seconds to stop on its own)
./wired live wave                                  # moving rainbow
```
Key names: a–z 0–9 esc tab caps enter space backspace delete arrows pgup pgdn end
ctrl shift alt cmd rctrl rshift ralt rcmd fn - = [ ] \\ ; ' ` , . /. Colours: names or #rrggbb.

### Over the 2.4G receiver — `f65 live` (only shows while the saved effect is **Fixed**)
Output reports `13 88 <total> <seq> <0x10+n> <14 data bytes> <checksum>`; data is colour groups
`R G B count slot…` (colours rounded to 0/85/170/255 so keys share groups; unlisted keys go dark).
Only slots holding a real key are sent, groups go out in a fixed order (otherwise keys flicker), and
frames may use up to 12 reports — **7-report frames confirmed working on the F65** (the F75 project caps at 6).

**Saving settings while live lighting runs:** every lighting/palette save makes the keyboard turn all its lights off
for a moment and then fade its own effect back in, and it ignores live frames until that fade-in ends. The app resends
the live picture 20×/s for 2 s after every save, so it takes over as soon as the keyboard allows. Setting the saved
effect's brightness to 0 keeps the fade-in dark: live colours are **not** dimmed by it (tested on the F65), but the keys
are dark when no app is streaming.

**What makes 2.4G smooth (all tested by eye on the F65):**
- **Space the reports.** The receiver drops reports sent back to back, so keys stall and then jump. 2 ms
  between the reports of a frame fixed it. This mattered far more than anything else.
- Send a frame only when it changes, plus a keep-alive every 0.4 s (the keyboard reverts after ~1 s).
- Exact colours when they fit; rounding to 0/85/170/255 only for frames that would be too big.
- Never send the hidden F-key row (row 0).
- The wave is a smooth flow at 20 fps, each column its own hue: 132 B, 10 reports, ~200 reports/s. It looked
  better than whole-column steps and than 12 or 16 fps.
- Tuning: `F65_FPS`, `F65_GAP` (ms), `F65_DUP` (send each new frame N times), `F65_STEPPED=1` with
  `F65_HUES`/`F65_STEP`; `F65_DEBUG=1` prints frames, bytes, reports and send times per second.

## Mac app — `app/`
`cd app && swift test && ./build.sh`, then `open "app/F65 Lighting.app"`. A menu-bar app with a main window
(**Open F65…**, ⌘O) that reads and saves the keyboard's own settings (effect, brightness, speed, colour,
palette, both key layers, restore points) through the same backup → write → verify → rollback routine as
`./f65`, and streams live lighting (solid colour, rainbow wave or a per-key `layout.json`). It picks the
cable or the 2.4G receiver automatically and pauses live frames during every settings read or write.
`./f65` still refuses to save while the app runs; quit the app to use the CLI. See [app/README.md](app/README.md).
```bash
./wired effect fixed                       # (cable) switch the saved effect to Fixed first
./f65 live test 15
./f65 live keys w=red a=red s=red d=red rest=off
./f65 live wave
```

**Safe saving (`f65`):** every settings change (`led`, `palette`, `remap`, `restore`, `poke`) goes through one
routine that
- uses the **USB cable automatically** when the keyboard is in wired mode (one 520-byte report per block, so a
  save is all-or-nothing); otherwise 2.4G (10–36 acknowledged packets);
- refuses while the menu-bar app is running (its live frames disturb reads and acknowledgements);
- checks the keyboard is answering, backs up to `backups/`, saves, then reads back every changed byte;
- retries once, then **rolls back** to the previous contents (verified) — or tells you the restore command.
Only changed bytes are compared: some bytes (e.g. lighting offset `0x0e`) change on their own.
Tested over 2.4G: normal saves, a forced verify failure (`F65_TEST_VERIFY_FAIL=1`) rolling back, and the
36-packet key map / 35-packet palette. The F75 project reports a brick from radio writes; for one-off big
changes (remaps, palette) plugging in the cable is still the safest.