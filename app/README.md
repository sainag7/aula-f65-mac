# F65 Lighting (Mac app + menu bar)

A native macOS app (SwiftPM, SwiftUI + AppKit, no Xcode project) for the AULA F65. It does two
separate things:

- **Onboard settings, saved on the keyboard**: effect, per-effect brightness / speed / colour, the
  7-colour palette, and both key layers (base and Fn). These keep working with the app closed.
  Every save goes backup → write → read back and verify → retry → verified rollback, using only
  write commands 01 (keys), 04 (lighting) and 09 (palette).
- **Live lighting, streamed by the app**: Solid, Rainbow wave or a custom `layout.json`, 20 frames a
  second. Nothing is stored; about a second after streaming stops the keyboard shows its saved
  effect again.

## Build and test

Requires Xcode (Swift 6.4 toolchain), macOS 13 or later.

```bash
cd app
swift test            # F65Kit unit tests (packets, retries, rollback, blocks, backups, key map)
./build.sh            # release build → app/F65 Lighting.app (ad-hoc signed)
open "F65 Lighting.app"
```

`build.sh` runs `swift build`, assembles the bundle in `.build/` with `Info.plist` and
`Resources/keyboard/` (the offline 3D/flat keyboard view), signs it, and only then replaces
`F65 Lighting.app`. Bundle id `local.f65.lighting`, executable `F65Lighting`.

Without hardware, run against the in-memory mock keyboard (no HID device is opened):

```bash
F65_MOCK=1 "app/F65 Lighting.app/Contents/MacOS/F65Lighting"               # explore every screen
F65_MOCK=1 F65_SMOKE=1 "app/F65 Lighting.app/Contents/MacOS/F65Lighting"   # scripted check, quits when done
```

## Main window

Open it from the menu-bar icon → **Open F65…** (⌘O). The Dock icon shows only while the window is
open. A launch at login stays menu-bar only.

| Section | What it does |
|---|---|
| Lighting | Keyboard view, effect grid (hover previews in the app only, click saves), brightness / speed / colour for the current effect, palette editor with Reset to factory |
| Live lighting | Off / Solid / Rainbow wave / Custom layout, brightness %, pause, connection preference |
| Keys | Base / Fn layer, click a key (or pick it from the list) to see its binding and remap, disable or restore it. Fn and connection bindings ask for confirmation first |
| Macros | Read-only. Shows whether macro memory is empty |
| Restore points | Every save makes one first. Back up now, Import… (the CLI's `backups/*.txt` work), Reveal, Restore… |
| Settings | Keyboard view: 3D model or Flat (Flat lay / Glass / Outline), camera, colourway. Start at login |

Unconfirmed values are labelled in the UI: speed direction (0–4) and the battery estimate from `4A`.
Effect previews are approximations drawn in the app.

## Using it

A keyboard icon appears in the menu bar. There's no Dock icon. The icon is greyed out while
nothing is being streamed.

| Menu item | What it does |
|---|---|
| Status line | `Cable — streaming`, `2.4G receiver — streaming`, `Not connected`, … |
| Mode | **Off** (stop streaming), **Solid colour**, **Rainbow wave**, **Custom layout** |
| Choose Colour… | Opens the colour panel; picking a colour switches to Solid colour |
| Brightness | 100 / 75 / 50 / 25 % (scales whatever is streamed) |
| Pause / Resume | Stops streaming without forgetting the mode |
| Edit Layout… | Opens `layout.json` in your default editor for `.json` (or TextEdit) |
| Reload Layout | Re-reads `layout.json` and shows an alert if it has problems (changes are also picked up automatically within ~2 s) |
| Connection | Automatic (prefer cable) · USB cable only · 2.4G receiver only |
| Start at Login | Registers the app as a login item (`SMAppService`). macOS may ask you to approve it in System Settings → General → Login Items |
| Quit | Quits; the keyboard returns to its own effect after ~1 s |

The mode, colour, brightness, pause state and connection choice are remembered (UserDefaults,
domain `local.f65.lighting`).

## Custom layout file

`~/Library/Application Support/F65Lighting/layout.json` (created with an example on first use):

```json
{
  "rest": "#100020",
  "keys": {
    "esc": "#00ffff",
    "w": "#ff0000", "a": "#ff0000", "s": "#ff0000", "d": "#ff0000",
    "space": "#ffffff"
  }
}
```

- `rest`: colour for every key not listed (`"#000000"` or `"off"` = dark).
- `keys`: key name → colour. Colours are `#rrggbb`, `#rgb`, or one of `red green blue yellow purple
  magenta cyan white orange pink off`.
- Key names: `a`–`z`, `0`–`9`, `esc tab caps enter space backspace delete pgup pgdn home end
  up down left right`, `- = [ ] \ ; ' , . /`, modifiers `lctrl lshift lalt lcmd rctrl rshift ralt
  rcmd` (also `ctrl shift alt option cmd`, which mean the left one), `fn`, and `slotN` to address
  LED slot N directly (slot = column × 6 + row). Names the keyboard doesn't have are listed in the
  menu under "Layout: unknown keys …".

Keys are found through the keyboard's own key map (read over the cable when the app connects and
cached in `~/Library/Application Support/F65Lighting/keymap.hex`), so remapped keys follow their
new function. If no map can be read, a built-in copy of the factory map is used.

## Connections

- **USB cable** (258A:010C, wired mode): one 520-byte feature report per frame. Preferred when both
  are present. Confirmed working.
- **2.4G receiver** (3554:FA09): up to six 20-byte output reports per frame, colours grouped and
  quantised to fit. **Live frames only show while the keyboard's saved effect is "Fixed on"**; the
  app doesn't change that for you (set it with the Fn shortcuts or `./f65 led effect fixed` over
  the cable). Settings reads and writes over the receiver go packet by packet, each write
  packet acknowledged; the cable is recommended for big changes (remaps, palette, restores).
  Live streaming pauses during every settings read or write.

Plugging and unplugging is handled automatically. If the keyboard stops answering (asleep, mode
switch), the app quietly retries every ~2 s. It also stops streaming while the Mac or the display
sleeps and resumes on wake.

## Permissions (Input Monitoring)

The keyboard's lighting interface sits on the same USB device as its keys, so the first time the
app opens it macOS may show **"F65 Lighting" would like to receive keystrokes from any
application** (Input Monitoring). The app never reads keystrokes; it only sends lighting
frames, but macOS asks for any app that opens a keyboard's HID device. Allow it in
System Settings → Privacy & Security → Input Monitoring, then quit and reopen the app.
If you denied it, the status line says "Needs Input Monitoring permission".

Ad-hoc signatures change on every build, so after rebuilding macOS may ask again (or you may need
to remove the old "F65 Lighting" entry from the Input Monitoring list and re-add it).

## Troubleshooting

Run the binary from a terminal with debug logging:

```bash
F65_DEBUG=1 "app/F65 Lighting.app/Contents/MacOS/F65Lighting"
```

It prints device arrivals, key-map reads, frame counts and failures. Only one copy of the app runs
at a time; a second copy quits immediately.

## Files

| File | Contents |
|---|---|
| `Sources/F65Kit/DeviceService.swift` | Owns the HID hub, live frame timer and every settings transaction (pauses streaming, backs up, saves, reloads) |
| `Sources/F65Kit/HIDHub.swift` | IOHIDManager matching/removal, input-report inbox on its own queue so acks arrive during a write |
| `Sources/F65Kit/Transport.swift` | Cable and 2.4G settings transports (read reassembly, per-packet acks and resends) |
| `Sources/F65Kit/Blocks.swift` | Lighting block, palette, key layers, snapshot, physical key ↔ slot table |
| `Sources/F65Kit/BackupStore.swift` | Restore-point files and `safeSave` (port of `f65.swift` `save()`) |
| `Sources/F65Kit/MockTransport.swift` | In-memory keyboard and packet-level fault injection for tests and `F65_MOCK=1` |
| `Sources/F65Kit/Protocol.swift`, `Engine.swift`, `KeyMap.swift`, `Layout.swift`, `Colors.swift`, `KeyNames.swift` | Live-frame encoders and renderer, key map, `layout.json`, colours, key names |
| `Sources/F65Lighting/AppDelegate.swift` | Menu-bar menu, settings, login item, window opening |
| `Sources/F65Lighting/MainWindow.swift`, `LightingView.swift`, `KeysView.swift`, `DeviceViews.swift` | Main window and its sections |
| `Sources/F65Lighting/KeyboardView.swift`, `Resources/keyboard/` | WKWebView keyboard (three.js r147 vendored, offline) and its JS bridge |
| `Sources/F65Lighting/SmokeTest.swift` | Mock-only scripted check (`F65_SMOKE=1`) |
| `Tests/F65KitTests/` | Unit tests |
| `Package.swift`, `Info.plist`, `build.sh` | Package, bundle metadata, build script |

## 2.4G receiver notes (tested on the F65)
- Reports of a frame go out 2 ms apart: back to back, the receiver drops some and keys stall, then jump.
- Over the receiver the app sends a frame only when the picture changes, plus a keep-alive every 0.4 s,
  with exact colours when they fit (up to 12 reports per frame).
- The rainbow wave over 2.4G is a smooth flow at 20 fps, half a rainbow cycle per second, picked by eye
  over stepped bands and 12/16 fps. Over the cable it stays a continuous 20 fps gradient.
- Live frames only show while the keyboard's saved effect is **Fixed on**.
- Every rebuild changes the ad-hoc signature: remove **F65 Lighting** from Input Monitoring with −,
  add the new build with +, then reopen the app.
