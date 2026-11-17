# HANDOFF: F65 Mac app (mockup → real app, wired to the backend)

Written 2026-11-17 for Codex. Repo root: `/Users/sainagamalla/aula-f65`.

## 1. The task

The user's words: *"Put this into the mac app mockup and connect the front end to the back end. Don't ask me
to test anything until you are fully done and then I can test stuff. Analyze the whole backend and how
everything works before you start connecting stuff and adding features to the app."*

"This" is the **keyboard view** artifact <https://claude.ai/artifact/KNDuAs39b3ccP41WoW6oLN>
(local copy: `mockups/f65-keyboard-models.html`, same code). It is an interactive AULA F65 with:
a 3D model or a flat board, three flat styles, camera presets, two colourways, and an in-browser
simulation of the 18 onboard lighting effects.

"The mac app mockup" is **Direction A ("Mac app")** in `mockups/f65-frontend-directions.html`. It shows a
window with a title bar of status chips, a sidebar (Lighting / Keys / Macros / Restore points), the
keyboard preview, an inspector and an effect grid.

The deliverable is a real, native macOS app built from those two mockups. Every control has to drive the
keyboard through the existing Swift HID code.

### Working rules from the user

1. **Read and understand the whole backend before you wire anything.** Sections 3–5 summarise it, but read
   the source files too (the reading order is in §12).
2. **Do not ask the user to test anything until everything is finished.** Work without hardware: use a mock
   transport, unit tests and build checks (§10). When you are done, give the user **one** consolidated test
   checklist.
3. There is **no git repo**. Before you change anything, run `git init` and commit the current tree. That
   gives you a rollback point for code. `backups/` only covers the keyboard's own state.

---

## 2. TL;DR of where things stand

| Piece | State |
|---|---|
| `f65.swift` → `./f65` CLI | Working. It reads and writes lighting (04/44), the palette (09/49) and both key layers (01/41), over 2.4G or the cable. Every save does backup → write → verify → retry → rollback. It also streams live per-key lighting over 2.4G. |
| `wired.swift` → `./wired` | Working. It reads blocks over the USB cable, streams live per-key lighting, and sets the effect byte. |
| `app/` → **F65 Lighting.app** | Working menu-bar app (AppKit, no Dock icon). It streams **live** per-key lighting (Solid / Rainbow wave / Custom `layout.json`) over the cable or 2.4G. It **never** reads or writes keyboard settings. |
| Mockups | HTML only, not connected to anything. |
| Native settings UI | **Does not exist yet.** This is your job. |

All three Swift programs typecheck cleanly with the installed toolchain: Swift 6.4.2, Xcode at
`/Applications/Xcode.app`, macOS 27.2 arm64, SDK includes SwiftUI, WebKit, SceneKit and RealityKit. I checked
this with `swiftc -typecheck` on 2026-11-17. I did **not** run `app/build.sh`, because it deletes and re-signs
the bundle.

---

## 3. Hardware and protocol (what the backend talks to)

AULA F65, 67 keys (65% ANSI). Reverse-engineered from the Windows driver (`CDev3632` for 2.4G,
`CDevG5KB` for the cable). The full details are in `README.md`; this is what matters for the app.

### Two transports, same storage

| | 2.4G receiver | USB cable (wired mode) |
|---|---|---|
| VID:PID | `3554:FA09`, usage page `0xFF02` | `258A:010C`, the interface whose max feature report is ≥ 520 |
| Report | 20-byte **output** report ID `0x13`; replies come as **input** reports | 520-byte **feature** report ID `0x06`; SetReport, then GetReport |
| Packet | `13 cmd count index (sub<<4|len) data[14] checksum` (checksum = sum of bytes 0..18 & 0xFF) | `06 cmd sub 00 pages index lenLo lenHi data[≤512]`; a read sends `cmd|0x80` |
| Block write | 14 bytes per packet, **each packet acked** (LED = 10, palette = 35, key layer = 36 packets) | One report per block, so a write is all-or-nothing |
| Reliability | Drops packets. Reads retry and merge by index. Writes resend unacked packets up to 5× | Reliable |
| Online check | `07` → `1` when the keyboard is linked to the receiver (`0` = asleep or off) | Always online if the device is present |

Command mapping (2.4G → cable), from `F65.cableMap` (`f65.swift:95`):
`01/41` key matrix → cable `03` (504 B, sub = layer 0 base / 1 Fn) · `04/44` lighting → `04` (128 B) ·
`09/49` palette → `0A` (490 B) · `43` macros → `05` (512 B, **read only**).

### Confirmed vs not (only ship editable controls for ✅ writes)

| Feature | Read | Write | Notes |
|---|---|---|---|
| Online (`07`) | ✅ | — | Drives the "Online" chip and the wake prompt |
| Lighting block (`04/44`, 128 B) | ✅ | ✅ | Must end in `5a a5`. `save()` refuses to write without it |
| Effect (byte `0x0a`, 1–18) | ✅ | ✅ | Order = driver list: 1 Fixed … 18 Storm. 19–21 are not usable custom modes (21 = key lights off, status lights only). The CLI only allows 1–18 |
| Per-effect brightness `0x38+2·e` (0–4) | ✅ | ✅ | Every effect keeps its own brightness/speed/colour ("settings saved per effect") |
| Per-effect speed: high nibble of `0x39+2·e` (0–4) | ✅ | ✅ | **Direction unconfirmed** (is 0 slow or fast?). Mockups assume higher = faster |
| Per-effect colour: low nibble of `0x39+2·e` (0–6 palette index, 7 = multicolour) | ✅ | ✅ | |
| Palette (`09/49`, 490 B) | ✅ | ✅ | 23 groups × 7 RGB + 7-byte trailer. The CLI writes the same colour into all 23 groups. Factory: red, green, blue, yellow, magenta, cyan, white |
| Key matrix base/Fn (`01/41`, 504 B) | ✅ | ✅ | 4 B per slot, 126 slots, slot = col·6 + row |
| Macros (`43`) | ✅ | ❌ blocked | Show as a locked, read-only section |
| Onboard `4A` → `64 10` | ✅ | ❌ | `0x64` is *possibly* battery 100%. **Unconfirmed**: label it as an estimate or hide it |
| Game mode `02/42` | no reply | ❌ | Hidden |
| LED bytes `0x00–0x37` | ✅ | ❌ | Undecoded (direction, sleep, flags?) |
| Factory reset `06`, screen `0B`, firmware | — | ❌ **never** | Not even behind a debug flag |
| Live per-key frames | — | ✅ streaming | Cable: `06 08 00 00 01 00 7a 01` + 126 RGB, ≤ 20 fps. 2.4G: `13 88 …` colour-group reports, **only visible while the saved effect is Fixed (1)**. Nothing is stored; the keyboard reverts about 1 s after frames stop |

The keyboard also sends **unsolicited `0x0A` input reports** over 2.4G when it wakes and when lighting is
changed with Fn shortcuts. `diff44.txt` shows `13 0a 01 00 04 07 …` arriving right as byte `0x4e` changed.
Use these reports as the trigger to re-read `0x44`, so the UI follows changes made on the keyboard.

### Key matrix entry types (from `describeKey`, `f65.swift:481`)
`00 mods 00 usage` = key + modifier bitmask (`01` LCtrl `02` LShift `04` LAlt `08` LCmd `10` RCtrl `20` RShift
`40` RAlt `80` RCmd) · `02 00 hi lo` = consumer/media · `07 00 00 n` = lighting function n ·
`08 a b c` = system/connection (BT channel, 2.4G, …) · `0d 00 00 00` = Fn · all zero = disabled or empty.
**Do not let the UI overwrite `08 …` or `0d …` entries without a strong warning. Never offer them as remap
targets.** Breaking the connection or Fn keys on a wireless board is hard to undo.

---

## 4. Current architecture

```
                         ┌───────────────────────── macOS ──────────────────────────┐
  ./f65  (f65.swift)     │ IOHIDManager (one shot) ── F65 class                      │
   CLI, run-loop based   │   query()  read cmds 07/4x, 2.4G multi-packet or cable    │
                         │   write()  cmds 01/04/09 only (precondition)              │
                         │   save()   backup → write → verify → retry → rollback     │
                         │   sendLive() 2.4G live frames                             │
                         │   backups/ next to the binary                             │
                         ├───────────────────────────────────────────────────────────┤
  ./wired (wired.swift)  │ cable-only reads, live frames, `effect` byte write        │
                         ├───────────────────────────────────────────────────────────┤
  F65 Lighting.app       │ AppDelegate (NSStatusItem menu, UserDefaults)             │
   (app/Sources)         │      │ Settings ↓          ↑ EngineStatus (main queue)     │
                         │ Engine (serial queue "local.f65.lighting.io")             │
                         │   IOHIDManager matching + removal callbacks (hot-plug)    │
                         │   Link(.cable | .receiver) → CableProtocol/ReceiverProtocol│
                         │   20 fps DispatchSourceTimer → render() → send            │
                         │   KeyMap (read over cable, cached, built-in fallback)     │
                         │   LayoutSpec (layout.json)                                │
                         └───────────────────────────────────────────────────────────┘
                                   │ 2.4G 20-byte reports      │ cable 520-byte feature reports
                                   ▼                           ▼
                              AULA F65 (one set of storage: lighting, palette, key layers, macros)
```

### 4.1 `f65.swift` (797 lines), the settings backend
- **`F65` class** (`:26–202`). `init?()` matches both devices and opens them, and registers the 2.4G input
  report callback on the **current run loop** (`:59–65`). It prefers the cable when present (`viaCable`).
  - `query(cmd, sub, timeout, tries)` (`:167`) reads. Over 2.4G it sends a 1-packet request, collects
    `count` reply packets, merges retries by index and fills missing packets with zeros (with a warning).
    Over the cable it calls `cableRead` (`:108`), which sends `cmd|0x80`, waits 20 ms, calls GetReport and retries 3×.
  - `write(cmd, sub, data)` (`:136`): `precondition(cmd ∈ {01,04,09})`. Over the cable it is one report followed by a 100 ms
    settle. Over 2.4G each 14-byte packet waits for an echo with the same cmd and index, resending up to 5×. A NAK
    (bit 7 set) aborts. Non-matching packets go into `unsolicited`.
  - `waitPacket` spins `CFRunLoopRunInMode` (`:81`). **It relies on the input callback firing on the same
    run loop.** Keep this in mind when you move it into an app (see §8 pitfalls).
- **Safe save** `save(kb, cmd, sub, data:new, previous:old, backupFile)` (`:763`) does this:
  refuse if `pgrep -x F65Lighting` finds the app → validate the LED block end marker → 2.4G: require `07 == 1` →
  write → read back and compare **only the bytes that were meant to change** (some bytes, e.g. LED `0x0e`,
  drift by themselves) → second attempt → roll back to `old` (verified) → otherwise print the
  `./f65 restore <file>` command. `F65_TEST_VERIFY_FAIL=1` forces the rollback path.
- **Backup** `backup(kb)` (`:465`) reads `44/0, 41/0, 41/1, 49/0`, checks the sizes (128/504/504/490) and writes
  `backups/f65-YYYYMMDD-HHmmss.txt` **next to the executable**. Format: one line per block,
  `"<readcmd hex> <sub> <hex bytes…>"`. `restore` (`:306`) replays any subset of those lines through `save()`.
- **Commands**: `led` (`:369`), `palette` (`:536`), `remap` (`:439`, finds the physical key by its base-layer entry,
  skips slot 0), `keys`, `probe`, `diff`, `read`, `poke 44`, `backup`, `restore`, `live` (`:630`).
- **Tables**: `effectNames` (`:361`), `colorNames` (`:367`), `keyEntry` name→entry (`:412`), `describeKey` /
  `hidName` (`:481`, `:503`), `factoryPalette` (`:526`).
- Everything reports through `print`/`fputs` and **calls `exit()`** on failure. It cannot be reused by a GUI
  as it is.

### 4.2 `wired.swift` (202 lines)
A cable-only probe: `read(cmd, sub, length)` handles multi-page reads, `sendFrame` sends a live frame,
`effect <n>` writes byte `0x0a` (backup-free; prefer `f65 led effect`), and `live test|all|keys|wave`.

### 4.3 `app/` (F65 Lighting.app), the live-lighting backend you will build on
| File | What it does |
|---|---|
| `Sources/main.swift` | `NSApplication`, `.accessory` activation policy (no Dock icon) |
| `Sources/AppDelegate.swift` | `@MainActor`. Single-instance guard by bundle id. UserDefaults (`mode color brightness paused connection`). Status-item menu, colour panel, `layout.json` watcher (2 s mtime poll), login item via `SMAppService`, sleep/wake → `engine.setSuspended` |
| `Sources/Engine.swift` | `Engine` (`@unchecked Sendable`) owns a serial queue `q`, an `IOHIDManager` scheduled on `q` with matching/removal callbacks (hot-plug), and one `Link` (cable or receiver, cable preferred in `.auto`). Its 20 fps `DispatchSourceTimer` runs `tick()` → `ensureLink()` → `render()` → `Link.send`. Over 2.4G it sends only on change plus a 0.4 s keep-alive. After 20 consecutive failures it drops the link and retries in 2 s. `kIOReturnNotPermitted` → "Needs Input Monitoring permission" + `IOHIDRequestAccess`. It publishes `EngineStatus` on main **only when it changes** |
| `Sources/Protocol.swift` | Pure encoders. `CableProtocol.frame`, `keyMapRequest`. `ReceiverProtocol.stream/reports`: exact colours, then quantise 4/3/2 levels, then merge the smallest groups; ≤ 12 reports (168 B); stable group order so frames don't flicker |
| `Sources/KeyMap.swift` | 126-slot map, `litSlots` (non-empty, not row 0, not slot 0), name→slots, `fallback` factory map (hex), cache at `~/Library/Application Support/F65Lighting/keymap.hex`. `AppPaths` |
| `Sources/Layout.swift` | `layout.json` → `LayoutSpec`, `resolve(keyMap)` → 126-slot frame + unknown key names |
| `Sources/Colors.swift` | `RGB` (hex parse, names, hue, scale, distance) |
| `Info.plist` | bundle id `local.f65.lighting`, executable `F65Lighting`, `LSUIElement=true`, min macOS 13 |
| `build.sh` | `swiftc -O -module-name F65Lighting Sources/*.swift`, assembles the bundle, ad-hoc `codesign -s - --force --deep`. **It does `rm -rf "F65 Lighting.app"` first** |

Important existing behaviour: the app **never sends anything over the receiver except live frames** (no
reads or writes), and the CLI **refuses to save while `F65Lighting` is running**. Both rules exist because
live frames disturb reads and acks. Once the app does settings I/O itself, it has to enforce the same rule
internally by pausing the stream for the duration of any read or write.

### 4.4 Data on disk
| Path | Contents |
|---|---|
| `backups/f65-*.txt` | 19 restore points from 2026-11-17 (format above). Latest: `f65-20261117-042024.txt` |
| `backups/palette-factory.txt` | `49 0 …` factory palette only |
| `backup-settings-2026-11-17.txt`, `probe1.txt`, `probe2.txt`, `diff44.txt`, `backup-run.txt` | Captured CLI output. `probe*` = full dumps, `diff44` = live LED byte changes from Fn shortcuts |
| `~/Library/Application Support/F65Lighting/{layout.json,keymap.hex}` | App data |
| `f65`, `wired` | Compiled CLIs (rebuild with `swiftc -O -o f65 f65.swift`, same for `wired`) |

Latest backup decoded: effect 1 (Fixed), brightness 4, speed 3, colour 5 (cyan); Neon (11) is bri 2 / spd 4.

---

## 5. Mockups: what to take, what's wrong in them

### 5.1 Keyboard view, `mockups/f65-keyboard-models.html` (= the artifact)
- **Layout data** `ROWS` (`:159`): 67 keys with ids, widths and DOM `code`s. Positions are in units of 1u.
- **Colourways** `CWS` (`:179`): Grey White, Black Grey. Legends are chosen by cap luminance.
- **Effect simulator** `lightFor(eff, key, now)` (`:197`): approximations of the 18 onboard effects, returning
  `[hue, intensity]`. Reactive effects (4, 7, 9, 12) respond to `press()`. **`SLOT={bri:4,spd:2,col:7}` (`:196`) is
  hard-coded.** Feed it from the real LED block. `HUES` (the palette hues) are also hard-coded; feed them from the
  real palette (`0x49`, bytes 0–20 = 7 × RGB).
- **3D** `buildBoard` (`:292`) / `make3D` (`:334`): three.js **r147** (`three.min.js`,
  `examples/js/controls/OrbitControls.js`, `examples/js/environments/RoomEnvironment.js`), loaded from jsDelivr. Sculpted caps,
  per-key additive glow planes, raycast click-to-press, camera presets `PRESETS` (`:328`):
  three-quarter / top / front / close-up, 700 ms eased tween.
- **Flat** `makeFlat` (`:419`): DOM/CSS boards in three styles, **Flat lay**, **Glass**, **Outline** (CSS for an
  unused `iso` style exists as well).
- **Settings the app should offer** (the page says so explicitly): Display (3D model / Flat), Flat style,
  Camera, Colourway, plus the Lighting effect. The page saves mode and style in `localStorage` (`f65mode`, `f65style`);
  in the app use UserDefaults instead.
- Fonts: Hanken Grotesk + DM Sans from Google Fonts (OFL). Reduced motion: shows still frames.
- Drop the page chrome (title, "More 3D shots" row, HTML control bar). Native controls replace it.

### 5.2 Mac app, Direction A in `mockups/f65-frontend-directions.html` (`:275–315`)
- Title bar chips: `● Online`, `2.4G receiver 3554:FA09` (or cable), `Battery ~100%`.
- Sidebar: **Keyboard** → Lighting, Keys, Macros *(soon)*; **Device** → Restore points.
- **Lighting**: keyboard preview + inspector (effect name, "Settings saved per effect", Brightness 0–4
  segmented, Speed 0–4 segmented, Colour swatches) + **effect grid** (hover = preview only, click = write).
- **Keys**: Base / Fn layer toggle; click a key to see its entry bytes and description; pick a new
  key → remap (writes that layer only, after a backup). Fn-layer keys with a binding are outlined.
- **Macros**: locked card. Macro memory is readable (512 B, empty); writes are disabled.
- **Restore points**: list of backups, newest first, each with a Restore button.
- Status bar (`aria-live`): "Loaded from keyboard", write progress.
- Motion tokens (shared across all directions): **write progress** one segment per acked packet, 120 ms
  ease-out, amber flash on a resend; **waiting for keyboard** 2.4 s ease-in-out outline pulse while `07 == 0`;
  **remap flip** 340 ms spring (`response 0.34, damping 0.8`) once read-back verifies; **layer switch**
  220 ms in / 150 ms out crossfade, keys without an Fn binding dim; **hover preview** 180 ms crossfade, paused when
  the window is not key; **keypress echo** 120 ms dip; popover 200 ms open / 130 ms close. Respect Reduce Motion
  (crossfades instead of flips, still preview).
- Direction B (menu-bar popover: effect chips, brightness, "Open F65…", "Undo last change") was recommended
  alongside A in the same app.

### 5.3 Known errors in the mockups (the backend is the source of truth)
- The directions page says the CLI has "436 lines" (it has 797 now) and lists **per-key RGB `09/49` as "no reply"**.
  That is wrong: `09/49` is the **7-colour palette**, read and write confirmed. Per-key colour can't be *stored*;
  it only works as live streaming.
- Directions page `CNAME = Red, Orange, Yellow, Green, Cyan, Blue, Purple` is wrong. The real palette
  indices are 0 red, 1 green, 2 blue, 3 yellow, 4 magenta, 5 cyan, 6 white, 7 multicolour, and the user can redefine 0–6.
- Neither mockup has: the **palette editor** (confirmed write), the **live-lighting modes** from the menu-bar app
  (Off / Solid / Wave / Custom, brightness %, pause, connection preference, start at login, layout file), or a
  place for the keyboard-view display settings. Add them (§6).
- The Lighting dropdown in the artifact has "Off" (0). There is **no confirmed "off" effect write**. Map a UI
  "Off" to *brightness 0 on the current effect* (a confirmed byte and range), or leave it out.
- Keycap legends say "Win"/"Alt" because that is what the physical caps print. Keep them on the model, but use
  Mac names (⌘ Cmd / ⌥ Option) in the remap picker text.

---

## 6. Target app (recommended design)

### 6.1 One app, two lighting systems, explained in the UI
- **Onboard lighting** (saved on the keyboard): effect, brightness, speed, colour, palette. Works with the app
  closed.
- **Live lighting** (streamed by the app, nothing saved): Solid, Rainbow wave, Custom layout. Needs the app running.
  Over 2.4G it only shows on the Fixed effect.

When live lighting is streaming over the cable, it hides the onboard effect. The preview must show what the
keyboard is *actually* displaying: the streamed frame when streaming, otherwise the simulated onboard effect.

### 6.2 Evolve the existing app; don't start a second one
Keep bundle id `local.f65.lighting` and executable name **`F65Lighting`**. The CLI's `pgrep -x F65Lighting` guard and
the single-instance check depend on that name. Keep the status-item menu and add **"Open F65…"** (⌘O). It shows
the main window and switches the activation policy to `.regular` while the window is open, then back to `.accessory`
on close, so the app keeps today's menu-bar-only behaviour when no window is open.

Window sections (sidebar):
1. **Lighting**: keyboard view + inspector (brightness, speed, colour swatches from the real palette, "edit
   palette" popover with 7 colour wells + "Reset to factory") + effect grid (hover preview, click to save).
2. **Live lighting**: Off / Solid (colour well) / Rainbow wave / Custom layout (open, reload, problems list),
   brightness %, pause, connection preference. This replaces nothing: the menu still has the same items.
3. **Keys**: layer toggle, click a key → detail + remap picker, "Disable key", "Restore this key".
4. **Macros**: locked, read-only (show "empty" or the byte count from `43`).
5. **Restore points**: list, restore, "Back up now", reveal in Finder.
6. **Settings** (or a View menu/toolbar): Display 3D/Flat, Flat style, Camera, Colourway, Start at login.

Title-bar chips: link (Cable 258A:010C / 2.4G 3554:FA09 / Not connected), online state, battery (labelled as an
estimate) and Input Monitoring status when it is denied.

### 6.3 Code layout (recommended: SwiftPM, still no Xcode project)
```
app/
  Package.swift              tools 5.10 or set swiftLanguageModes [.v5] (see pitfalls)
  Sources/F65Kit/            library: transports, protocol, blocks, backup, safe save, key tables, mock
  Sources/F65Lighting/       executable: main, AppDelegate (menu), Engine, windows, SwiftUI views
  Tests/F65KitTests/         XCTest, `swift test`
  Resources/keyboard/        index.html (stripped artifact + bridge), vendor/three r147 files, fonts/
  Info.plist, build.sh       build.sh → `swift build -c release`, assemble bundle, copy Resources/keyboard
                             into Contents/Resources/keyboard, codesign
```
- Use `Bundle.main.url(forResource:"index", withExtension:"html", subdirectory:"keyboard")`. **Don't** use SwiftPM
  `resources:` for the executable: `Bundle.module` looks for a bundle at the `.app` root, which breaks code
  signing.
- **Leave `f65.swift` and `wired.swift` untouched in this pass.** They are the user's known-good recovery tools
  (`./f65 restore …`). Port their logic into F65Kit (with a source comment pointing back) and make the CLI a thin
  client later, only if there is time *and* tests cover it. If you do touch them, rebuild both binaries and
  keep every command's behaviour identical.

### 6.4 F65Kit API (shape, adjust as needed)
```swift
enum LinkKind { case cable, receiver }
enum F65Error: Error { case notFound, notPermitted, asleep, timeout(cmd: UInt8), nak(cmd: UInt8),
                       incomplete(cmd: UInt8, got: Int, expected: Int), invalidBlock(String),
                       verifyFailed(rolledBack: Bool, backup: URL), busy }
protocol Transport {                       // real: CableTransport, ReceiverTransport; test: MockTransport
  var kind: LinkKind { get }
  func read(_ cmd: UInt8, sub: UInt8, timeout: Double) throws -> [UInt8]          // 0x07 / 0x4x
  func write(_ cmd: UInt8, sub: UInt8, data: [UInt8], progress: (Int, Int, Bool) -> Void) throws // 01/04/09 only; (acked, total, wasResend)
  func sendLive(_ frame: [RGB], slots: [Int]) -> Bool
}
struct LightingBlock { var bytes: [UInt8]; var effect: Int; func brightness(_ e: Int) -> Int; func speed(_ e: Int) -> Int;
                       func colour(_ e: Int) -> Int; mutating setters…; var isValid: Bool }   // 0x38+2e etc.
struct Palette   { var colours: [RGB] /* 7 */; mutating func set(_ i: Int, _ c: RGB) /* all 23 groups */; static let factory }
struct KeyLayer  { var bytes: [UInt8]; func entry(slot:) -> KeyEntry; mutating func set(slot:, _:) }
enum KeyEntry    { case key(mods: UInt8, usage: UInt8), media(UInt16), lighting(UInt8), system(UInt8,UInt8,UInt8), fn, none, raw([UInt8]) }
struct Snapshot  { var lighting: LightingBlock; var palette: Palette; var base: KeyLayer; var fn: KeyLayer }
final class BackupStore { // ~/Library/Application Support/F65Lighting/backups/, same text format, also lists repo backups/ read-only
  func write(_ s: Snapshot) throws -> URL; func list() -> [RestorePoint]; func load(_ url: URL) throws -> [(cmd: UInt8, sub: UInt8, bytes: [UInt8])] }
func safeSave(_ t: Transport, cmd: UInt8, sub: UInt8, new: [UInt8], old: [UInt8], backup: URL,
              progress: …) throws          // same algorithm as f65.swift save(), minus pgrep, plus thrown errors
```
- **Backups must not go next to the executable** (inside the `.app` that breaks the signature). Use Application
  Support. In Restore points, also list the repo's `backups/` if it exists, read-only, or offer an "Import…".

### 6.5 Device ownership and concurrency (the hard part)
One `DeviceService` owns the `IOHIDManager`, the open links, the live `Engine` timer and every settings
transaction. Nothing else touches IOKit.
- Live streaming continues to run as it does today.
- A **transaction** (`func perform<T>(_ body: (Transport) throws -> T) async throws -> T`) does this: stop the frame timer →
  wait ~200 ms and drain the inbox → run the body → restart streaming. Transactions are serialised. The UI disables
  write controls while one is running and shows progress.
- 2.4G replies arrive through `IOHIDDeviceRegisterInputReportCallback`. The callback has to be delivered on a queue
  that is **not blocked** by the code waiting for acks. Today the Engine's manager is scheduled on `q`. If a
  transaction blocks `q` while waiting, the callback never fires and you deadlock. Options: run transactions on a
  separate queue and have the callback (on `q`) push into a locked inbox and signal a `DispatchSemaphore`. Or use a
  dedicated thread with its own run loop for the receiver device, the way the CLI does it.
- Publish `DeviceState` (link, online, battery estimate, snapshot, busy, last error, input-monitoring status) to a
  `@MainActor @Observable` model that SwiftUI reads.
- On connect: read a full snapshot (`44`, `49`, `41/0`, `41/1`; plus `4A`, `43` for display). Over 2.4G, first wait for
  `07 == 1` (show the "press any key to wake" pulse). On an unsolicited `0x0A` report: re-read `44` (pause the live
  stream first if it is running over 2.4G).
- Key map: the live engine already reads `41/0` over the cable and caches it. Share the snapshot's base layer
  with the engine so both use the same map, which now works over 2.4G too.

### 6.6 Keyboard view inside the app
**Recommended: `WKWebView`** hosting a trimmed copy of the artifact, with a JS ↔ Swift bridge. Reasons: it keeps
the model, the effect simulation and the three flat styles exactly as approved, and porting the sculpted caps and
effects to SceneKit would be a large rewrite with visible differences. SwiftUI owns every control around it.
- Vendor three@**0.147.0** `build/three.min.js`, `examples/js/controls/OrbitControls.js` and
  `examples/js/environments/RoomEnvironment.js` into `Resources/keyboard/vendor/` (the `examples/js` files were
  removed after r148, so stay on 0.147). Vendor the two OFL fonts with their license, or fall back to
  `-apple-system`. **No network at runtime.** Load with `loadFileURL(_:allowingReadAccessTo:)`.
- JS API to add (`window.f65`): `setState({display:'3d'|'flat', flatStyle:'lay'|'glass'|'out', camera, colourway,
  effect, brightness, speed, colour, palette:[[r,g,b]×7], preview: effect|null})`, `setLiveFrame([[r,g,b]×67] | null)`
  (≤ 20 fps), `press(id)`, `setSelected(id|null)`, `setLegends({id: text})` (Fn layer / remapped legends, then
  redraw that cap's texture), `setActive(bool)` (stop rendering when the window is hidden or occluded).
- Swift receives: `ready`, `keyClicked(id)`, `webglFailed` (fall back to Flat).
- Key echo: `NSEvent.addLocalMonitorForEvents(.keyDown)` while the window is key → map to mockup id → `press(id)`.
  Remove the page's own `keydown` listener so presses aren't counted twice. No global key monitoring.
- Transparent background: `webView.setValue(false, forKey: "drawsBackground")`.
- Speed mapping to the preview: `SPD[]`/`BRI[]` in the page take device values 0–4 directly.

### 6.7 Physical key ↔ LED slot (verified from the key map in `backups/f65-20261117-042024.txt`)
slot = column × 6 + row. Matrix row 0 is a hidden F-row with no physical keys or LEDs, so never light it. Mockup
row *y* = matrix row *y+1*.

| Mockup row | ids → slots |
|---|---|
| 0 (numbers) | esc 1, d1 7, d2 13, d3 19, d4 25, d5 31, d6 37, d7 43, d8 49, d9 55, d0 61, minus 67, equal 73, bksp 79, del 91 |
| 1 (QWERTY) | tab 2, q 8, w 14, e 20, r 26, t 32, y 38, u 44, i 50, o 56, p 62, lbr 68, rbr 74, bslash 80, pgup 92 |
| 2 (home) | caps 3, a 9, s 15, d 21, f 27, g 33, h 39, j 45, k 51, l 57, semi 63, quote 69, enter 81, pgdn 93 |
| 3 (shift) | lshift 4, z 10, x 16, c 22, v 28, b 34, n 40, m 46, comma 52, period 58, slash 64, rshift 82, up 88, end 94 |
| 4 (bottom) | lctrl 5, lwin 11, lalt 17, space 35, fn 59, rctrl 65, left 83, down 89, right 95 |

That is 67 keys. The map has one more lit slot, **75** (ISO `#`, usage `0x32`), which has no key on this ANSI
board, so the model has no cap for it. Slot 0 duplicates Esc and is skipped by `remap`.
Put this table in F65Kit as data and unit-test it against `KeyMap.fallback`.

Fn layer today (same backup): Esc → light fn 4; 1…= → F1…F12; Q/W/E/R/T → light fn 8/0/5/6/7; G → 10;
B → 17; LCtrl → 19; LCmd → 1; U/I/O → PrtSc/ScrLk/Pause; End → Home; Tab, `\`, `, . /`, RShift, Left, Right →
system functions (`08 …`, connection or BT related, **protected**). The hidden row-0 Fn entries are media keys.

---

## 7. Control → backend wiring

| UI | F65Kit call | Bytes |
|---|---|---|
| Effect tile click | `perform { safeSave(04, new: lighting.with(effect: e)) }` | `0x0a = e` (1–18) |
| Brightness segment | same, setter on the current effect | `0x38+2e` = 0–4 |
| Speed segment | same | `0x39+2e` high nibble |
| Colour swatch | same | `0x39+2e` low nibble 0–7 |
| Palette colour well (commit on close, not on every drag) | `safeSave(09, palette.set(i, rgb))` | 23 groups × slot i |
| Palette reset | `safeSave(09, .factory)` | |
| Remap key | find the slot via §6.7 (or base-layer entry like the CLI), `safeSave(01, sub: layer, …)` | 4 B at slot·4 |
| Restore point | for each line of the file: read current → `safeSave(cmd & 0x0F, …)`. Show combined progress (10+36+36+35 packets over 2.4G) | |
| Back up now | `BackupStore.write(snapshot)` | |
| Live mode / colour / brightness % / pause / connection | existing `Engine.update(Settings)` | live frames only |
| Hover effect tile | preview only (`setState({preview})`), **no I/O** | |

Every write: `BackupStore.write` first (as the CLI does), then `safeSave`, then refresh the snapshot from the
read-back. On `verifyFailed(rolledBack: true)` say "Nothing was changed". On `rolledBack: false` show the backup
path and a one-click Restore. Use the CLI's message texts; they are already user-tested wording.
Over 2.4G, if the user changes the effect away from Fixed while live lighting is on, warn that live frames will
stop showing.

---

## 8. Invariants and pitfalls (read before coding)

- **Write allow-list is 01, 04, 09.** Keep the precondition in F65Kit's transports. No 02, 03, 06, 0A, 0B, firmware.
- **Never write without a fresh backup and a verified read-back.** Compare only the bytes that were meant to change.
- **LED block must keep `5a a5`** at 126–127 and be exactly 128 bytes. Palette is 490 bytes, key layer 504.
- **Prefer the cable for writes** when both are present (one report = atomic). The F75 project reports a brick from
  radio writes. For big writes over 2.4G (remap, palette, restore), show a soft "plug in the cable for big changes" hint.
- **Pause live streaming during any read or write.** Live frames break reads and acks.
- 2.4G live: 2 ms between reports of a frame, ≤ ~70 reports/s, send on change + 0.4 s keep-alive, never row 0,
  ≤ 12 reports per frame. Cable live: ≤ 20 fps (faster starves key scanning).
- Incomplete 2.4G reads come back zero-filled with only a warning in the CLI. In the app, treat an incomplete
  read as an **error** for anything you will write back.
- Swift 6.4 toolchain: SwiftPM with tools-version 6.x enables Swift 6 strict concurrency, and the existing code
  (`@unchecked Sendable`, C callbacks with `Unmanaged`, `MainActor.assumeIsolated`) will not compile cleanly
  under it. Use tools 5.10 or `swiftLanguageModes: [.v5]`.
- **Input Monitoring**: opening the keyboard's HID device triggers it. Ad-hoc signatures change on every build,
  so macOS may ask again (remove and re-add the entry). Detect `kIOReturnNotPermitted`, show a clear banner with an
  "Open System Settings" button (`x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`).
- `build.sh` deletes the bundle. Never point it at anything else. The CLI `backup()` writes next to its own binary.
  Don't reuse that for the app.
- Effect speed direction and the battery byte are **unconfirmed**. Don't present them as facts.
- Effects in the preview are **approximations** drawn in the app. Keep a small "Preview is approximate" note.

---

## 9. Suggested order of work

1. `git init`, commit. Read the files in §12. Write down anything in this doc that turns out to be wrong.
2. **F65Kit**: protocol, transports (cable, receiver with the non-blocking inbox), blocks, key tables, backup store,
   `safeSave`, `MockTransport` (in-memory keyboard with configurable drops, NAKs, verify failures and asleep state). Tests.
   *Done when* `swift test` passes and covers every §10 item.
3. Move the existing app onto SwiftPM + F65Kit with **no behaviour change** (menu, live modes, hot-plug).
   *Done when* `build.sh` produces a bundle and the menu works against the mock.
4. `DeviceService` + transactions + snapshot model; the existing Engine runs inside it.
5. Main window shell (sidebar, title chips, status bar, activation-policy switching, "Open F65…").
6. Keyboard view: vendored web assets, bridge, display settings persisted, key echo, live-frame mirroring.
7. Lighting section wired end to end, with write progress driven by real acks; palette editor.
8. Keys section (remap, layer switch, protected entries, flip animation after verify).
9. Restore points, Back up now, Macros (locked), Live lighting section, Settings.
10. Motion pass with the §5.2 tokens + Reduce Motion; error and empty states (no keyboard, asleep, permission
    denied, WebGL failed → Flat).
11. Update `README.md` and `app/README.md` (the app now reads and writes settings; the "never touches settings
    over the receiver" statement is no longer true). Then write the user test checklist (§10).

## 10. Verifying without hardware, then the one hand-back

Unit tests (XCTest via `swift test`):
- 2.4G packet + checksum encoding; cable header; `cableMap` sizes.
- Read reassembly: out-of-order packets, dropped packets merged across retries, NAK, timeout, incomplete → error.
- Write: per-packet ack, resend on a missing ack (progress reports `wasResend`), NAK aborts, allow-list rejects other cmds.
- `LightingBlock` getters and setters against the real bytes in `backups/*.txt` (e.g. Neon = bri 2, spd 4, col 7).
- `Palette.set` touches all 23 groups and leaves the 7-byte trailer alone; factory round-trip with `backups/palette-factory.txt`.
- `KeyEntry` parse/describe round-trips; remap finds the right slot; slot table (§6.7) matches `KeyMap.fallback`.
- `BackupStore` writes and parses the exact text format and reads every existing file in `backups/`.
- `safeSave`: success, verify fail → retry → success, verify fail ×2 → rollback verified, rollback fails → error carries backup URL.
- `ReceiverProtocol` frames ≤ 12 reports and stable ordering (existing behaviour).

Also: `swiftc -typecheck f65.swift` and `wired.swift` still pass; `build.sh` builds; the app launches with
`F65_MOCK=1` (add this: a DeviceService backed by `MockTransport`) and every screen works against the mock.

**Hand-back to the user** (only when everything above is done). One checklist covering: re-grant Input
Monitoring; cable: snapshot loads, change effect/brightness/speed/colour, edit and reset the palette, remap a key and
restore it, restore a restore point, Fn shortcut on the keyboard updates the app; 2.4G: the same plus the wake prompt
and write progress; live lighting modes on both links; unplug and replug; sleep and wake; the `./f65` CLI still works
and still refuses to save while the app runs.

## 11. Open questions (don't block on these; mark them in the UI)
- Speed 0–4 direction. Battery meaning of `4A[0]`. What LED bytes `0x00–0x37` do. Whether slot 75 has an LED.
- Whether live frames over 2.4G need anything besides effect = Fixed.
- Unsolicited `0A` report layout (`13 0a 01 00 04 07 …` and `05 64 10 00` seen).

## 12. Reading order
`README.md` → `f65.swift` (all of it) → `wired.swift` → `app/README.md` → `app/Sources/Engine.swift` →
`Protocol.swift` → `KeyMap.swift` → `AppDelegate.swift` → `Layout.swift`, `Colors.swift`, `main.swift` →
`app/build.sh`, `app/Info.plist` → `mockups/f65-keyboard-models.html` → Direction A + Motion catalogue in
`mockups/f65-frontend-directions.html` → one file in `backups/` + `diff44.txt` + `probe1.txt`.

---

## 13. Files modified or created

**This handoff session (Claude, 2026-11-17):**
| File | Change |
|---|---|
| `HANDOFF.md` | **Created** (this file) |

No source, build, mockup or data file in the repo was modified. Analysis was read-only: `swiftc -typecheck` on
`f65.swift`, `wired.swift` and `app/Sources/*.swift` (all clean), plus a throwaway decode script kept outside the
repo in a temp folder.

**Earlier frontend work (Claude frontend sessions, same day; there is no git history to confirm authorship):**
| File | What it is |
|---|---|
| `mockups/f65-frontend-directions.html` | Four frontend directions (Mac app, menu bar, WebHID, terminal UI), capability table, motion catalogue, recommendation. Published as artifact `XtVzJNUQqDDgeyHKvdTfoS` |
| `mockups/f65-keyboard-models.html` | The keyboard view (3D model + flat styles). Same code as artifact `KNDuAs39b3ccP41WoW6oLN`, the one this task is about |

Everything else (`f65.swift`, `wired.swift`, `app/**`, `README.md`, `backups/`, the probe/diff captures and the compiled
binaries) is the existing backend, written in other sessions. Treat it as the reference implementation.

## Implementation corrections (Codex)

- The approximate 70 reports/s limit in §8 conflicts with the existing 20 fps receiver wave
  (about 200 reports/s) and README. The integrated service will conservatively budget receiver
  frames to 70 reports/s while retaining 2 ms packet gaps and 0.4 s keep-alives. Cable stays at
  20 fps. This is a deliberate change from the old wave rate, pending hardware validation.
- The logical settings write allow-list is 01/04/09. Cable translation necessarily uses
  03/04/0A on the wire; those are the same confirmed blocks, not additional write features.
  Existing transient live frames remain a separate streaming API (cable 08 / receiver 88),
  as required by the Live lighting section; they do not save keyboard settings.
- Rollback verification checks every stable byte (excluding documented volatile LED 0x0e),
  rather than only edited bytes: a partially failed transfer could affect other bytes.
- Battery 4A has no confirmed cable mapping, so the cable UI shows unavailable/unconfirmed.
- The repository's initial probe1.txt contains incomplete old reads. It is diagnostic evidence,
  not a valid snapshot fixture. Restore files are parsed strictly and never zero-filled.
