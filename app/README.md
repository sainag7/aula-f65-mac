# F65 Lighting (menu-bar app)

A small native macOS menu-bar app (Swift + AppKit, no dependencies, no Xcode project) that keeps
live per-key lighting running on an AULA F65. The F65 can't store per-key colours, so the app
streams a frame to it 20 times a second. About a second after the app stops (Off, Pause, Quit, or
the Mac/display going to sleep), the keyboard goes back to its own saved effect. Nothing is
written to the keyboard's memory.

## Build

Requires only the Xcode Command Line Tools (`swiftc`, `codesign`), macOS 13 or later.

```bash
cd app
./build.sh            # release build → app/F65 Lighting.app (ad-hoc signed)
./build.sh debug      # unoptimised build with debug info
open "F65 Lighting.app"
```

The build compiles `Sources/*.swift` with `swiftc`, assembles the bundle with `Info.plist`
(`LSUIElement` = true, bundle id `local.f65.lighting`) and signs it with `codesign -s - --force --deep`.
You can move the `.app` to `/Applications` if you like.

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
  the cable). The app sends nothing over the receiver except live frames: it never reads or
  writes settings through it. This path hasn't been confirmed on the F65 yet.

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
| `Sources/main.swift` | App entry point (accessory app, no Dock icon) |
| `Sources/AppDelegate.swift` | Menu-bar UI, settings, colour panel, layout file handling, login item |
| `Sources/Engine.swift` | IOHIDManager matching/removal, device open/retry, 20 fps frame loop, effects |
| `Sources/Protocol.swift` | Cable frame and 2.4G report encoders |
| `Sources/KeyMap.swift` | Key names → slots, built-in fallback map, key-map cache |
| `Sources/Layout.swift` | `layout.json` parsing |
| `Sources/Colors.swift` | Colour parsing, hue, scaling |
| `Info.plist`, `build.sh` | Bundle metadata and build script |

## 2.4G receiver notes (tested on the F65)
- Reports of a frame go out 2 ms apart: back to back, the receiver drops some and keys stall, then jump.
- Over the receiver the app sends a frame only when the picture changes, plus a keep-alive every 0.4 s,
  with exact colours when they fit (up to 12 reports per frame).
- The rainbow wave over 2.4G is a smooth flow at 20 fps, half a rainbow cycle per second, picked by eye
  over stepped bands and 12/16 fps. Over the cable it stays a continuous 20 fps gradient.
- Live frames only show while the keyboard's saved effect is **Fixed on**.
- Every rebuild changes the ad-hoc signature: remove **F65 Lighting** from Input Monitoring with −,
  add the new build with +, then reopen the app.
