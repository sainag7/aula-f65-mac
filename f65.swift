// f65 — talk to an AULA F65 (2.4G receiver 3554:FA09, wired 258A:010C) on macOS.
//
// Protocol (reverse-engineered from the official Windows driver, class "CDev3632"):
//   20-byte output/input report, report ID 0x13 on vendor usage page 0xFF02.
//   [0]=0x13 [1]=cmd [2]=packet count [3]=packet index [4]=(sub<<4)|len
//   [5..18]=up to 14 data bytes  [19]=sum(bytes 0..18) & 0xFF
//   Write commands: 0x01 matrix, 0x02 game, 0x03 macro, 0x04 LED, 0x06 reset,
//                   0x09 RGB table, 0x0A onboard, 0x0B screen
//   Read commands:  0x07 online, 0x41 matrix, 0x42 game, 0x43 macro,
//                   0x44 LED, 0x49 RGB table, 0x4A onboard
//
// This build is READ-ONLY: it refuses to send any write command.

import Foundation
import IOKit.hid

let kReportID: UInt8 = 0x13
let devices: [(vid: Int, pid: Int, name: String)] = [
    (0x3554, 0xFA09, "2.4G receiver"),
    (0x258A, 0x010C, "USB cable"),
]

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
func checksum(_ p: [UInt8]) -> UInt8 { UInt8(p[0..<19].reduce(0) { ($0 + Int($1)) & 0xFF }) }

final class F65 {
    let dev: IOHIDDevice?      // 2.4G receiver control interface (usage page 0xFF02)
    let cable: IOHIDDevice?    // USB cable, 520-byte feature report 6 — preferred for saving settings
    var viaCable: Bool { cable != nil }
    var inbox: [[UInt8]] = []
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    var verbose = false

    init?() {
        func open(_ d: IOHIDDevice) -> Bool {
            let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
            if r != kIOReturnSuccess {
                fputs("Could not open the keyboard's control interface (IOReturn 0x\(String(UInt32(bitPattern: r), radix: 16))).\n", stderr)
                fputs("If macOS asked for Input Monitoring permission, allow it for your terminal app and rerun.\n", stderr)
            }
            return r == kIOReturnSuccess
        }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, [
            [kIOHIDVendorIDKey: 0x3554, kIOHIDProductIDKey: 0xFA09, kIOHIDPrimaryUsagePageKey: 0xFF02],
            [kIOHIDVendorIDKey: 0x258A, kIOHIDProductIDKey: 0x010C],
        ] as CFArray)
        let all = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
        func int(_ d: IOHIDDevice, _ k: String) -> Int { IOHIDDeviceGetProperty(d, k as CFString) as? Int ?? 0 }
        let c = all.first { int($0, kIOHIDVendorIDKey) == 0x258A && int($0, kIOHIDMaxFeatureReportSizeKey) >= 520 }
        let r = all.first { int($0, kIOHIDVendorIDKey) == 0x3554 }
        cable = c.flatMap { open($0) ? $0 : nil }
        dev = r.flatMap { open($0) ? $0 : nil }
        guard let dev = self.dev else {
            if cable == nil { return nil }
            return   // cable only
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { ctx, _, _, _, id, report, len in
            let me = Unmanaged<F65>.fromOpaque(ctx!).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: len))
            if bytes.first != UInt8(id) { bytes.insert(UInt8(id), at: 0) }   // normalise: always lead with report ID
            if bytes.first == kReportID { me.inbox.append(bytes) }
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    var product: String { viaCable ? "USB cable (wired mode)" : (dev.flatMap { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String } ?? "?") }
    var pid: Int { (cable ?? dev).flatMap { IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int } ?? 0 }

    func send(_ p: [UInt8]) -> Bool {
        guard let dev else { return false }
        if verbose { print("  >> \(hex(p))") }
        let r = p.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(kReportID), $0.baseAddress!, p.count)
        }
        if r != kIOReturnSuccess { fputs("  send failed: 0x\(String(UInt32(bitPattern: r), radix: 16))\n", stderr) }
        return r == kIOReturnSuccess
    }

    func waitPacket(timeout: Double) -> [UInt8]? {
        let end = Date().addingTimeInterval(timeout)
        while inbox.isEmpty && Date() < end {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        return inbox.isEmpty ? nil : inbox.removeFirst()
    }

    /// Read command (0x07 or 0x40–0x4F). Returns the reassembled payload.
    var unsolicited: [[UInt8]] = []

    // MARK: Cable transport (driver class CDevG5KB): one 520-byte feature report per ≤512-byte block,
    // `06 cmd sub 00 pages index lenLo lenHi data…`; reads send `cmd|0x80` then GetReport.
    // 2.4G command → cable command and block length. A whole block is one report, so a save is all-or-nothing.
    static let cableMap: [UInt8: (cmd: UInt8, len: Int)] = [
        0x01: (0x03, 504), 0x41: (0x03, 504),   // key matrix (sub = layer)
        0x04: (0x04, 128), 0x44: (0x04, 128),   // lighting settings
        0x09: (0x0A, 490), 0x49: (0x0A, 490),   // colour palette
        0x43: (0x05, 512),                      // macros (read only)
    ]

    func cableHeader(_ cmd: UInt8, sub: UInt8, len: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 520)
        p[0] = 0x06; p[1] = cmd; p[2] = sub; p[4] = 1; p[5] = 0; p[6] = UInt8(len & 0xFF); p[7] = UInt8(len >> 8)
        return p
    }

    func cableRead(_ d: IOHIDDevice, _ cmd: UInt8, sub: UInt8) -> [UInt8]? {
        guard let m = F65.cableMap[cmd] else { return nil }
        let p = cableHeader(m.cmd | 0x80, sub: sub, len: m.len)
        for _ in 0..<3 {
            let r1 = p.withUnsafeBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 6, $0.baseAddress!, 520) }
            if r1 != kIOReturnSuccess { usleep(70_000); continue }
            usleep(20_000)
            var buf = [UInt8](repeating: 0, count: 520)
            var len = CFIndex(520)
            let r2 = buf.withUnsafeMutableBufferPointer { IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 6, $0.baseAddress!, &len) }
            if r2 == kIOReturnSuccess && buf[1] == m.cmd | 0x80 { return Array(buf[8..<(8 + m.len)]) }
            usleep(70_000)
        }
        return nil
    }

    func cableWrite(_ d: IOHIDDevice, _ cmd: UInt8, sub: UInt8, data: [UInt8]) -> Bool {
        guard let m = F65.cableMap[cmd], data.count == m.len else { fputs("  cable: unexpected block size\n", stderr); return false }
        var p = cableHeader(m.cmd, sub: sub, len: m.len)
        p.replaceSubrange(8..<(8 + data.count), with: data)
        if verbose { print("  >> cable \(hex(Array(p[0..<16])))…") }
        let r = p.withUnsafeBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 6, $0.baseAddress!, 520) }
        usleep(100_000)   // let the keyboard commit before the verify read
        return r == kIOReturnSuccess
    }

    /// Write command (0x01 matrix, 0x04 LED only — others stay blocked). Mirrors CDev3632::AccessData:
    /// 14 bytes per packet, each packet acknowledged by an echo carrying the same cmd and index.
    func write(_ cmd: UInt8, sub: UInt8 = 0, data: [UInt8], timeout: Double = 2.0) -> Bool {
        precondition([0x01, 0x04, 0x09].contains(cmd), "write of cmd 0x\(String(cmd, radix: 16)) not enabled")
        if let cable { return cableWrite(cable, cmd, sub: sub, data: data) }
        let count = (data.count + 13) / 14
        for idx in 0..<count {
            let chunk = Array(data[(idx * 14)..<min(data.count, idx * 14 + 14)])
            var p = [UInt8](repeating: 0, count: 20)
            p[0] = kReportID; p[1] = cmd; p[2] = UInt8(count); p[3] = UInt8(idx)
            p[4] = (sub << 4) | UInt8(chunk.count)
            for (i, b) in chunk.enumerated() { p[5 + i] = b }
            p[19] = checksum(p)
            var acked = false
            for _ in 0..<5 {
                inbox.removeAll()
                guard send(p) else { return false }
                let end = Date().addingTimeInterval(timeout)
                while Date() < end, let r = waitPacket(timeout: end.timeIntervalSinceNow) {
                    if verbose { print("  << \(hex(Array(r.prefix(20))))") }
                    guard r.count >= 20, checksum(r) == r[19] else { continue }
                    if r[1] & 0x7F != cmd { unsolicited.append(Array(r.prefix(20))); continue }
                    if r[1] & 0x80 != 0 { fputs("  keyboard rejected packet \(idx) (NAK)\n", stderr); return false }
                    if Int(r[3]) == idx { acked = true; break }
                }
                if acked { break }
                if verbose { print("  (no ack for packet \(idx), resending)") }
            }
            if !acked { fputs("  no acknowledgement for packet \(idx)/\(count); stopping\n", stderr); return false }
        }
        return true
    }

    func query(_ cmd: UInt8, sub: UInt8 = 0, timeout: Double = 2.0, tries: Int = 8) -> [UInt8]? {
        precondition(cmd == 0x07 || (cmd & 0xF0) == 0x40, "read-only build: refusing cmd 0x\(String(cmd, radix: 16))")
        if let cable { return cmd == 0x07 ? [1] : cableRead(cable, cmd, sub: sub) }
        var chunks: [Int: [UInt8]] = [:]   // packet index -> data; merged across retries
        var expected = -1
        for attempt in 0..<tries {
            inbox.removeAll()
            var p = [UInt8](repeating: 0, count: 20)
            p[0] = kReportID; p[1] = cmd; p[2] = 1; p[3] = 0; p[4] = sub << 4
            p[19] = checksum(p)
            if attempt > 0 && verbose { print("  (retry \(attempt), have \(chunks.count)/\(expected))") }
            guard send(p) else { return nil }
            while true {
                guard let r = waitPacket(timeout: timeout), r.count >= 20 else {
                    if verbose { print("  (timeout)") }
                    break
                }
                if verbose { print("  << \(hex(Array(r[0..<20])))") }
                if checksum(r) != r[19] { if verbose { print("  (bad checksum, ignored)") }; continue }
                if r[1] & 0x7F != cmd & 0x7F { unsolicited.append(Array(r[0..<20])); continue }
                if r[1] & 0x80 != 0 { fputs("  device rejected cmd 0x\(String(cmd, radix: 16)) (NAK)\n", stderr); return nil }
                expected = Int(r[2] & 0x7F)
                let n = min(Int(r[4] & 0x0F), 14)
                chunks[Int(r[3])] = Array(r[5..<(5 + n)])
                if chunks.count >= expected { break }
            }
            if expected > 0 && chunks.count >= expected { break }
        }
        if chunks.isEmpty { return nil }
        if expected > 0 && chunks.count < expected {
            fputs("  warning: cmd 0x\(String(cmd, radix: 16)) incomplete, got \(chunks.count)/\(expected) packets (missing filled with 00)\n", stderr)
        }
        let count = max(expected, (chunks.keys.max() ?? 0) + 1)
        return (0..<count).flatMap { chunks[$0] ?? [UInt8](repeating: 0, count: 14) }
    }
}

// MARK: - CLI

func dump(_ title: String, _ data: [UInt8]?) {
    print("\n== \(title)")
    guard let d = data else { print("   (no reply)"); return }
    print("   \(d.count) bytes")
    for off in stride(from: 0, to: d.count, by: 16) {
        let row = Array(d[off..<min(off + 16, d.count)])
        print(String(format: "   %04x: ", off) + hex(row))
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard let kb = F65() else {
    fputs("AULA F65 not found. Plug in the 2.4G receiver (or the USB cable) and wake the keyboard.\n", stderr)
    exit(1)
}
kb.verbose = args.contains("-v")
print("Found: \(kb.product) (PID 0x\(String(kb.pid, radix: 16)))")

let cmdArgs = args.filter { $0 != "-v" }
var online = kb.query(0x07)?.first ?? 0
if online == 0 {
    print("Keyboard is asleep or not on 2.4G. Switch it to 2.4G mode and press any key… (waiting 60 s)")
    let end = Date().addingTimeInterval(60)
    while online == 0 && Date() < end {
        CFRunLoopRunInMode(.defaultMode, 0.5, true)
        online = kb.query(0x07, timeout: 0.5)?.first ?? 0
    }
    if online == 0 { print("Keyboard not connected."); exit(3) }
    print("Keyboard connected.")
    CFRunLoopRunInMode(.defaultMode, 0.5, true)
}
// Settings changes need the keyboard to themselves: the menu-bar app's live frames disturb both the
// reads and the packet acknowledgements of a save.
let changesSettings: Bool = {
    switch cmdArgs.first {
    case "led": return cmdArgs.count >= 3
    case "palette": return cmdArgs.count >= 2
    case "remap", "restore", "poke": return true
    default: return false
    }
}()
if changesSettings && appIsStreaming() {
    fputs("F65 Lighting is running and sending to the keyboard. Quit it (menu → Quit F65 Lighting), then retry.\nNothing was changed.\n", stderr)
    exit(1)
}
switch cmdArgs.first ?? "probe" {
case "probe":
    dump("0x44 LED / lighting settings", kb.query(0x44))
    dump("0x4A onboard settings", kb.query(0x4A))
    dump("0x42 game-mode settings", kb.query(0x42))
    dump("0x49 per-key RGB table", kb.query(0x49, timeout: 3))
    dump("0x41 key matrix, layer 0 (base)", kb.query(0x41, sub: 0, timeout: 3))
    dump("0x41 key matrix, layer 1 (Fn)", kb.query(0x41, sub: 1, timeout: 3))
    dump("0x43 macros", kb.query(0x43, timeout: 3))
    if !kb.unsolicited.isEmpty {
        print("\n== Unsolicited status reports from the keyboard")
        kb.unsolicited.forEach { print("   \(hex($0))") }
    }
case "read":
    // f65 read <cmd-hex> [sub]
    guard cmdArgs.count >= 2, let c = UInt8(cmdArgs[1].replacingOccurrences(of: "0x", with: ""), radix: 16),
          c == 0x07 || (c & 0xF0) == 0x40 else {
        fputs("usage: f65 read <0x07|0x40-0x4F> [sub]\n", stderr); exit(2)
    }
    let sub = cmdArgs.count > 2 ? UInt8(cmdArgs[2]) ?? 0 : 0
    dump("cmd 0x\(String(c, radix: 16)) sub \(sub)", kb.query(c, sub: sub, timeout: 3))
case "keys":
    // Decode the key matrix. 4 bytes per slot, column-major, 6 rows per column.
    for layer: UInt8 in [0, 1] {
        guard let m = kb.query(0x41, sub: layer, timeout: 3) else { print("layer \(layer): no reply"); continue }
        print("\n== Layer \(layer) (\(layer == 0 ? "base" : "Fn"))")
        for i in 0..<(m.count / 4) {
            let e = Array(m[(i * 4)..<(i * 4 + 4)])
            if e == [0, 0, 0, 0] { continue }
            print(String(format: "   col %2d row %d: ", i / 6, i % 6) + describeKey(e))
        }
    }
case "diff":
    // Watch a settings block and print which bytes change. Read-only.
    let c = cmdArgs.count > 1 ? UInt8(cmdArgs[1].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x44 : 0x44
    let seconds = cmdArgs.count > 2 ? Double(cmdArgs[2]) ?? 1e9 : 1e9
    let stopAt = Date().addingTimeInterval(seconds)
    print("Watching cmd 0x\(String(c, radix: 16)). Change lighting with the Fn shortcuts; Ctrl-C to stop.")
    var last = kb.query(c, timeout: 3)
    dump("starting state", last)
    while Date() < stopAt {
        CFRunLoopRunInMode(.defaultMode, 1.0, true)
        guard let now = kb.query(c, timeout: 3), let prev = last, now.count == prev.count else { continue }
        let changed = (0..<now.count).filter { now[$0] != prev[$0] }
        if !changed.isEmpty {
            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            print("[\(ts)] " + changed.map { String(format: "@%02x: %02x→%02x", $0, prev[$0], now[$0]) }.joined(separator: "  "))
            last = now
        }
        kb.unsolicited.forEach { print("   (status report: \(hex($0)))") }
        kb.unsolicited.removeAll()
    }
case "backup":
    print(backup(kb) ?? "backup failed")
case "restore":
    // f65 restore <file>  — writes LED block and both key layers back
    guard cmdArgs.count > 1, let txt = try? String(contentsOfFile: cmdArgs[1], encoding: .utf8) else {
        fputs("usage: f65 restore backups/<file>.txt\n", stderr); exit(2)
    }
    guard let bk = backup(kb) else { fputs("backup of the current state failed, not restoring\n", stderr); exit(1) }
    for line in txt.split(separator: "\n") {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count > 2, let c = UInt8(parts[0], radix: 16), let s = UInt8(parts[1]) else { continue }
        let bytes = parts[2...].compactMap { UInt8($0, radix: 16) }
        let wc: UInt8 = c & 0x0F
        guard let current = kb.query(c, sub: s, timeout: 3), current.count == bytes.count else {
            fputs("could not read cmd 0x\(String(c, radix: 16)) sub \(s); skipped\n", stderr); continue
        }
        print("restoring cmd 0x\(String(wc, radix: 16)) sub \(s) (\(bytes.count) bytes):")
        _ = save(kb, wc, sub: s, data: bytes, previous: current, backupFile: bk)
    }
case "poke":
    // f65 poke 44 <offset-hex> <value-hex>  — change one byte of the LED block (backs up first)
    guard cmdArgs.count == 4, cmdArgs[1] == "44",
          let off = Int(cmdArgs[2], radix: 16), let val = UInt8(cmdArgs[3], radix: 16) else {
        fputs("usage: f65 poke 44 <offset-hex> <value-hex>\n", stderr); exit(2)
    }
    guard var led = kb.query(0x44, timeout: 3), led.count == 128, off < 126 else { fputs("could not read LED block\n", stderr); exit(1) }
    guard let file = backup(kb) else { exit(1) }
    print("backup: \(file)")
    print(String(format: "LED[0x%02x]: %02x → %02x", off, led[off], val))
    let original = led
    led[off] = val
    guard save(kb, 0x04, data: led, previous: original, backupFile: file) else { exit(1) }
case "live":
    liveCommand(kb, Array(cmdArgs.dropFirst()))
case "led":
    ledCommand(kb, Array(cmdArgs.dropFirst()))
case "palette":
    paletteCommand(kb, Array(cmdArgs.dropFirst()))
case "remap":
    remapCommand(kb, Array(cmdArgs.dropFirst()))
default:
    print("""
    usage: f65 <command> [-v]
      led                          show current lighting
      led effect <name|number>     \(effectNames.map { $0.1 }.joined(separator: ", "))
      led brightness <0-4>         led speed <0-4>      led color <name|0-7>
      palette [<0-6|name> <color|#rrggbb> | reset]   change what the 7 colours look like
      remap <key> <new-key> [--fn] e.g. remap capslock lctrl · remap rctrl mute · remap f --fn play
      live [test | all <color> | keys k=color… [rest=color] | wave] [seconds]   per-key lighting over 2.4G
      keys                         show the key map        backup / restore <file>
      probe | diff [cmd] | read <cmd> [sub] | poke 44 <off> <val>   (low-level)
    """)
}

// MARK: - Lighting

// Effect numbers = position in the official driver's effect list (confirmed: 1 Fixed, 11 Neon stream).
var effectNames: [(Int, String)] { [
    (1, "fixed"), (2, "breathing"), (3, "rainbow"), (4, "flash-away"), (5, "raindrops"), (6, "rainbow-wheel"),
    (7, "ripples"), (8, "stars"), (9, "shadow"), (10, "snake"), (11, "neon"), (12, "reaction"),
    (13, "sine-wave"), (14, "scanning"), (15, "windmill"), (16, "waterfall"), (17, "blossom"), (18, "storm"),
] }
// Colour = index into the 7-colour palette (factory order below; change with `f65 palette`); 7 = multicolour.
var colorNames: [String] { ["red", "green", "blue", "yellow", "magenta", "cyan", "white", "rainbow"] }

func ledCommand(_ kb: F65, _ a: [String]) {
    guard var led = kb.query(0x44, timeout: 3), led.count == 128, led[126] == 0x5A, led[127] == 0xA5 else {
        fputs("could not read the lighting block\n", stderr); exit(1)
    }
    let original = led
    let effect = Int(led[0x0A])
    func slot(_ e: Int) -> Int { 0x38 + 2 * e }
    func show() {
        let s = slot(Int(led[0x0A])), e = Int(led[0x0A])
        let name = effectNames.first { $0.0 == e }?.1 ?? "#\(e)"
        let c = Int(led[s + 1] & 0x0F)
        print("effect: \(name)  brightness: \(led[s])/4  speed: \(led[s + 1] >> 4)/4  color: \(c < colorNames.count ? colorNames[c] : String(c))")
    }
    guard a.count >= 2 else { show(); return }
    let value = a[1].lowercased()
    switch a[0] {
    case "effect":
        guard let e = Int(value) ?? effectNames.first(where: { $0.1 == value })?.0, (1...18).contains(e) else {
            fputs("unknown effect '\(value)'\n", stderr); exit(2)
        }
        led[0x0A] = UInt8(e)
    case "brightness":
        guard let v = UInt8(value), v <= 4 else { fputs("brightness is 0–4\n", stderr); exit(2) }
        led[slot(effect)] = v
    case "speed":
        guard let v = UInt8(value), v <= 4 else { fputs("speed is 0–4\n", stderr); exit(2) }
        led[slot(effect) + 1] = (v << 4) | (led[slot(effect) + 1] & 0x0F)
    case "color", "colour":
        guard let v = UInt8(value) ?? colorNames.firstIndex(of: value).map(UInt8.init), v <= 7 else {
            fputs("color is 0–7 or one of: \(colorNames.joined(separator: ", "))\n", stderr); exit(2)
        }
        led[slot(effect) + 1] = (led[slot(effect) + 1] & 0xF0) | v
    default:
        fputs("led effect|brightness|speed|color <value>\n", stderr); exit(2)
    }
    guard let bk = backup(kb) else { fputs("backup failed, not writing\n", stderr); exit(1) }
    guard save(kb, 0x04, data: led, previous: original, backupFile: bk) else { exit(1) }
    show()
}

// MARK: - Remapping

/// Parse a key name into a 4-byte matrix entry.
func keyEntry(_ raw: String) -> [UInt8]? {
    let n = raw.lowercased()
    let mods: [String: UInt8] = ["lctrl": 0x01, "ctrl": 0x01, "lshift": 0x02, "shift": 0x02, "lalt": 0x04, "alt": 0x04,
        "option": 0x04, "lcmd": 0x08, "cmd": 0x08, "lwin": 0x08, "win": 0x08, "rctrl": 0x10, "rshift": 0x20,
        "ralt": 0x40, "roption": 0x40, "rcmd": 0x80, "rwin": 0x80]
    if let m = mods[n] { return [0x00, m, 0x00, 0x00] }
    let media: [String: Int] = ["mute": 0xE2, "volup": 0xE9, "voldown": 0xEA, "play": 0xCD, "next": 0xB5,
        "prev": 0xB6, "stop": 0xB7, "brightup": 0x6F, "brightdown": 0x70]
    if let u = media[n] { return [0x02, 0x00, UInt8(u >> 8), UInt8(u & 0xFF)] }
    if n == "none" || n == "disable" { return [0x00, 0x00, 0x00, 0x00] }
    let named: [String: UInt8] = ["enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29, "backspace": 0x2A,
        "tab": 0x2B, "space": 0x2C, "-": 0x2D, "minus": 0x2D, "=": 0x2E, "equal": 0x2E, "[": 0x2F, "]": 0x30,
        "\\": 0x31, "backslash": 0x31, ";": 0x33, "'": 0x34, "`": 0x35, "grave": 0x35, ",": 0x36, ".": 0x37,
        "/": 0x38, "capslock": 0x39, "caps": 0x39, "printscreen": 0x46, "scrolllock": 0x47, "pause": 0x48,
        "insert": 0x49, "home": 0x4A, "pageup": 0x4B, "pgup": 0x4B, "delete": 0x4C, "del": 0x4C, "end": 0x4D,
        "pagedown": 0x4E, "pgdn": 0x4E, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52, "menu": 0x65,
        "#": 0x32]
    if let u = named[n] { return [0, 0, 0, u] }
    if n.count == 1, let c = n.unicodeScalars.first {
        if ("a"..."z").contains(n) { return [0, 0, 0, UInt8(c.value - 97 + 0x04)] }
        if n == "0" { return [0, 0, 0, 0x27] }
        if ("1"..."9").contains(n) { return [0, 0, 0, UInt8(c.value - 49 + 0x1E)] }
    }
    if n.hasPrefix("f"), let k = Int(n.dropFirst()), (1...12).contains(k) { return [0, 0, 0, UInt8(0x39 + k)] }
    return nil
}

func remapCommand(_ kb: F65, _ a: [String]) {
    let fn = a.contains("--fn")
    let p = a.filter { $0 != "--fn" }
    guard p.count == 2, let from = keyEntry(p[0]), let to = keyEntry(p[1]), from != [0, 0, 0, 0] else {
        fputs("usage: f65 remap <physical-key> <new-key> [--fn]   (key names: a-z 0-9 f1-f12 esc tab caps enter space\n" +
              "       backspace delete arrows pgup pgdn home end lctrl lshift lalt lcmd rctrl rshift ralt rcmd\n" +
              "       mute volup voldown play next prev, or none to disable)\n", stderr); exit(2)
    }
    // Locate the physical key by its base-layer entry. Skip column 0 row 0 (a hidden duplicate Esc slot).
    guard let base = kb.query(0x41, sub: 0, timeout: 3), base.count == 504 else { fputs("could not read key map\n", stderr); exit(1) }
    var slots: [Int] = []
    for i in 1..<(base.count / 4) where Array(base[(i * 4)..<(i * 4 + 4)]) == from { slots.append(i) }
    guard !slots.isEmpty else { fputs("'\(p[0])' not found on the base layer (already remapped? use restore)\n", stderr); exit(1) }
    let layer: UInt8 = fn ? 1 : 0
    guard var m = layer == 0 ? base : kb.query(0x41, sub: 1, timeout: 3), m.count == 504 else { fputs("could not read Fn layer\n", stderr); exit(1) }
    guard let bk = backup(kb) else { fputs("backup failed, not writing\n", stderr); exit(1) }
    let original = m
    for s in slots {
        print(String(format: "%@ col %d row %d: %@ → %@", fn ? "Fn layer" : "base layer", s / 6, s % 6,
                     describeKey(Array(m[(s * 4)..<(s * 4 + 4)])), describeKey(to)))
        m.replaceSubrange((s * 4)..<(s * 4 + 4), with: to)
    }
    guard save(kb, 0x01, sub: layer, data: m, previous: original, backupFile: bk) else { exit(1) }
}

/// Save LED block + both key layers. Line format: "<readcmd> <sub> <hex bytes…>"
func backup(_ kb: F65) -> String? {
    var lines: [String] = []
    for (c, s) in [(UInt8(0x44), UInt8(0)), (0x41, 0), (0x41, 1), (0x49, 0)] {
        guard let d = kb.query(c, sub: s, timeout: 3) else { fputs("backup: could not read 0x\(String(c, radix: 16))\n", stderr); return nil }
        let complete = (c == 0x44 && d.count == 128) || (c == 0x41 && d.count == 504) || (c == 0x49 && d.count == 490)
        if !complete { fputs("backup: 0x\(String(c, radix: 16)) incomplete (\(d.count) bytes)\n", stderr); return nil }
        lines.append(String(format: "%02x %d ", c, s) + hex(d))
    }
    let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("backups")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
    let url = dir.appendingPathComponent("f65-\(f.string(from: Date())).txt")
    do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
    return url.path
}

func describeKey(_ e: [UInt8]) -> String {
    let raw = hex(e)
    switch e[0] {
    case 0x00:
        var parts: [String] = []
        let mods = ["LCtrl", "LShift", "LAlt", "LCmd/Win", "RCtrl", "RShift", "RAlt", "RCmd/Win"]
        for b in 0..<8 where e[1] & (1 << b) != 0 { parts.append(mods[b]) }
        if e[3] != 0 { parts.append(hidName(e[3])) }
        return "\(raw)  key: \(parts.joined(separator: "+"))"
    case 0x02:
        let u = Int(e[2]) << 8 | Int(e[3])
        let names: [Int: String] = [0xE2: "Mute", 0xE9: "Volume+", 0xEA: "Volume-", 0xCD: "Play/Pause",
                                    0xB5: "Next track", 0xB6: "Prev track", 0xB7: "Stop", 0x6F: "Screen brightness+",
                                    0x70: "Screen brightness-", 0x18A: "Mail", 0x223: "Browser home", 0x192: "Calculator",
                                    0x194: "My computer", 0x183: "Media player", 0x22A: "Favorites"]
        return "\(raw)  media: \(names[u] ?? String(format: "consumer 0x%03x", u))"
    case 0x07: return "\(raw)  lighting function #\(e[3])"
    case 0x08: return "\(raw)  system/connection function \(String(format: "%02x %02x %02x", e[1], e[2], e[3]))"
    default:   return "\(raw)  type 0x\(String(e[0], radix: 16))"
    }
}

func hidName(_ u: UInt8) -> String {
    switch u {
    case 0x04...0x1D: return String(UnicodeScalar(UInt8(ascii: "A") + u - 0x04))
    case 0x1E...0x26: return String(u - 0x1D)
    case 0x27: return "0"
    case 0x3A...0x45: return "F\(u - 0x39)"
    default:
        let n: [UInt8: String] = [0x28: "Enter", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space", 0x2D: "-",
            0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\", 0x32: "#", 0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",",
            0x37: ".", 0x38: "/", 0x39: "CapsLock", 0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause",
            0x49: "Insert", 0x4A: "Home", 0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End", 0x4E: "PageDown",
            0x4F: "Right", 0x50: "Left", 0x51: "Down", 0x52: "Up", 0x65: "Menu"]
        return n[u] ?? String(format: "0x%02x", u)
    }
}

// MARK: - Colour palette (cmd 09/49, 490 bytes)
// 23 groups of 7 colours (R,G,B each) + 7-byte trailer. The effect "color" setting 0–6 picks one of the 7.
// Factory: red, green, blue, yellow, magenta, cyan, white in every group (confirmed by reading the keyboard).

var rgbNames: [String: [UInt8]] { ["red": [255, 0, 0], "orange": [255, 80, 0], "yellow": [255, 200, 0],
    "green": [0, 255, 0], "cyan": [0, 255, 255], "blue": [0, 0, 255], "purple": [160, 0, 255],
    "magenta": [255, 0, 255], "pink": [255, 0, 120], "white": [255, 255, 255]] }
let factoryPalette: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [255, 0, 255], [0, 255, 255], [255, 255, 255]]

func parseRGB(_ v: String) -> [UInt8]? {
    let n = v.lowercased()
    if let c = rgbNames[n] { return c }
    let h = n.hasPrefix("#") ? String(n.dropFirst()) : n
    guard h.count == 6, let x = UInt32(h, radix: 16) else { return nil }
    return [UInt8(x >> 16 & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF)]
}

func paletteCommand(_ kb: F65, _ a: [String]) {
    guard var tab = kb.query(0x49, timeout: 3), tab.count == 490 else {
        fputs("could not read the colour palette (wireless dropout?) — press a key on the keyboard and try again\n", stderr); exit(1)
    }
    let original = tab
    func set(_ k: Int, _ c: [UInt8]) { for g in 0..<23 { tab.replaceSubrange((g * 21 + k * 3)..<(g * 21 + k * 3 + 3), with: c) } }
    switch a.first?.lowercased() {
    case nil:
        for k in 0..<7 { print("  \(k) \(colorNames[k]): " + String(format: "#%02x%02x%02x", tab[k * 3], tab[k * 3 + 1], tab[k * 3 + 2])) }
        return
    case "reset":
        for k in 0..<7 { set(k, factoryPalette[k]) }
    default:
        guard a.count == 2, let k = Int(a[0]) ?? colorNames.firstIndex(of: a[0].lowercased()), k < 7, let c = parseRGB(a[1]) else {
            fputs("usage: f65 palette                      show the 7 colours\n       f65 palette <0-6|name> <color|#rrggbb>\n       f65 palette reset\n", stderr); exit(2)
        }
        set(k, c)
    }
    guard let bk = backup(kb) else { fputs("backup failed, not writing\n", stderr); exit(1) }
    guard save(kb, 0x09, data: tab, previous: original, backupFile: bk) else { exit(1) }
    print("palette updated")
}

// MARK: - Live per-key lighting over the 2.4G receiver (nothing stored; only shows on the Fixed effect)
// Output reports: 13 88 <total> <seq> <0x10+n> <14 data bytes> <checksum>; data = groups "R G B count slot…".
// Unlisted slots go dark. Format from github.com/Itzadetunji/aula-f75-mac-driver.

extension F65 {
    func sendLive(_ colors: [[UInt8]], keys: Set<Int>) -> Bool {
        let maxBytes = liveMaxReports * 14
        var step = 1   // exact colours first; round to 0/85/170/255 (then coarser) only if the frame is too big
        var data: [UInt8] = []
        while true {
            var groups: [[UInt8]: [UInt8]] = [:]
            for (slot, c) in colors.prefix(126).enumerated() where keys.contains(slot) && (c[0] | c[1] | c[2]) != 0 {
                var q = c.map { UInt8(min(255, (Int($0) + step / 2) / step * step)) }
                if q == [0, 0, 0], let top = c.max() { q = c.map { $0 == top ? UInt8(min(255, step)) : 0 } }
                groups[q, default: []].append(UInt8(slot))
            }
            if groups.isEmpty { groups[[0, 0, 0]] = [0] }
            // Stable order (by size, then colour) so a frame never reshuffles; a cut-off would otherwise flicker.
            let ordered = groups.sorted {
                $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key.lexicographicallyPrecedes($1.key)
            }
            data = ordered.flatMap { $0.key + [UInt8($0.value.count)] + $0.value.sorted() }
            if data.count <= maxBytes || step >= 256 { break }
            step = step == 1 ? 85 : step * 2
        }
        if data.count > maxBytes { fputs("warning: frame too large for 2.4G, \(data.count - maxBytes) bytes dropped\n", stderr) }
        liveStats.bytes += min(data.count, maxBytes); liveStats.frames += 1
        let chunks = stride(from: 0, to: min(data.count, maxBytes), by: 14).map { Array(data[$0..<min($0 + 14, data.count)]) }
        for (seq, chunk) in chunks.enumerated() {
            var r = [UInt8](repeating: 0, count: 20)
            r[0] = 0x13; r[1] = 0x88; r[2] = UInt8(chunks.count); r[3] = UInt8(seq); r[4] = UInt8(0x10 + chunk.count)
            r.replaceSubrange(5..<(5 + chunk.count), with: chunk)
            r[19] = checksum(r)
            if seq > 0, liveGapMs > 0 { usleep(useconds_t(liveGapMs * 1000)) }   // optional spacing between reports
            let t0 = Date()
            if !send(r) { return false }
            liveStats.reports += 1
            let dt = Date().timeIntervalSince(t0) * 1000
            liveStats.sendMs += dt; liveStats.maxSendMs = max(liveStats.maxSendMs, dt)
        }
        return true
    }
}

/// Pause between the reports of one frame. Back-to-back reports get dropped by the receiver
/// (keys stall, then jump); 2 ms was enough at 20 fps on the F65.
var liveGapMs: Double { Double(ProcessInfo.processInfo.environment["F65_GAP"] ?? "") ?? 2 }
var waveHues: Double { Double(ProcessInfo.processInfo.environment["F65_HUES"] ?? "") ?? 8 }

struct LiveStats { var frames = 0, reports = 0, bytes = 0; var sendMs = 0.0, maxSendMs = 0.0 }
var liveStats = LiveStats()

/// Packets per live frame. The F75 project caps at 6; the vendor driver's SetRealData has no fixed cap.
var liveMaxReports: Int { 12 }

func liveColor(_ s: String) -> [UInt8]? {
    let names: [String: [UInt8]] = ["red": [255, 0, 0], "green": [0, 255, 0], "blue": [0, 0, 255], "yellow": [255, 170, 0],
        "purple": [170, 0, 255], "cyan": [0, 255, 255], "white": [255, 255, 255], "orange": [255, 85, 0], "pink": [255, 0, 170], "off": [0, 0, 0]]
    if let c = names[s.lowercased()] { return c }
    let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard h.count == 6, let x = UInt32(h, radix: 16) else { return nil }
    return [UInt8(x >> 16 & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF)]
}

func liveHSV(_ h: Double) -> [UInt8] {
    let x = h * 6, i = Int(x) % 6, f = x - Double(Int(x))
    let q = UInt8((1 - f) * 255), t = UInt8(f * 255)
    switch i { case 0: return [255, t, 0]; case 1: return [q, 255, 0]; case 2: return [0, 255, t]
    case 3: return [0, q, 255]; case 4: return [t, 0, 255]; default: return [255, 0, q] }
}

func liveCommand(_ kb: F65, _ a: [String]) {
    if kb.viaCable { fputs("The keyboard is on the USB cable (wired mode): use ./wired live … instead.\n", stderr); exit(2) }
    if let led = kb.query(0x44, timeout: 3), led.count == 128, led[0x0A] != 1 {
        print("Note: live lighting over 2.4G only shows on the Fixed effect (current effect #\(led[0x0A])).")
        print("      Switch with Fn shortcuts, or with the cable plugged in: ./f65 led effect fixed")
    }
    // Only slots that hold a real key (from the key map); hidden/empty slots would waste radio bytes.
    guard let keyMap = kb.query(0x41, sub: 0, timeout: 3), keyMap.count == 504 else { fputs("could not read key map\n", stderr); exit(1) }
    // Row 0 is the F65's hidden F-key row (F1–F12 in the map, no physical keys/LEDs): leave it out.
    let keySlots = Set((1..<126).filter { $0 % 6 != 0 && keyMap[$0 * 4..<$0 * 4 + 4].contains { $0 != 0 } })
    let mode = a.first ?? "test"
    var secs = Double.infinity
    var frame: (Double) -> [[UInt8]]
    switch mode {
    case "test":
        secs = a.count > 1 ? Double(a[1]) ?? 15 : 15
        let rows: [[UInt8]] = [[0, 0, 0], [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 170, 0], [255, 255, 255]]
        frame = { _ in (0..<126).map { rows[$0 % 6] } }
        print("Row test: number row red, Q row green, A row blue, Z row yellow, bottom row white")
    case "all":
        guard a.count > 1, let c = liveColor(a[1]) else { fputs("usage: f65 live all <color> [seconds]\n", stderr); exit(2) }
        if a.count > 2 { secs = Double(a[2]) ?? secs }
        frame = { _ in Array(repeating: c, count: 126) }
    case "keys":
        guard let map = kb.query(0x41, sub: 0, timeout: 3), map.count == 504 else { fputs("could not read key map\n", stderr); exit(1) }
        var rest: [UInt8] = [0, 0, 0]
        var assigned: [(Int, [UInt8])] = []
        for arg in a.dropFirst() {
            if let s = Double(arg) { secs = s; continue }
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let c = liveColor(kv[1]) else { fputs("bad argument '\(arg)' (use key=color)\n", stderr); exit(2) }
            if kv[0].lowercased() == "rest" { rest = c; continue }
            let e: [UInt8]? = kv[0].lowercased() == "fn" ? [0x0D, 0, 0, 0] : keyEntry(kv[0])
            guard let entry = e, entry != [0, 0, 0, 0] else { fputs("unknown key '\(kv[0])'\n", stderr); exit(2) }
            let slots = (1..<126).filter { Array(map[($0 * 4)..<($0 * 4 + 4)]) == entry }
            guard !slots.isEmpty else { fputs("key '\(kv[0])' not found\n", stderr); exit(2) }
            slots.forEach { assigned.append(($0, c)) }
        }
        var f = [[UInt8]](repeating: rest, count: 126)
        for (s, c) in assigned { f[s] = c }
        let fixed = f
        frame = { _ in fixed }
    case "wave":
        if a.count > 1 { secs = Double(a[1]) ?? secs }
        // The rainbow moves in whole-column steps at a steady rate, so a frame only changes (and only
        // goes over the radio) when it moves. Bands are few so a frame fits in ~7 reports.
        let speed = Double(ProcessInfo.processInfo.environment["F65_STEP"] ?? "") ?? 8   // columns per second
        // Smooth flow at 20 fps with 2 ms between reports was picked by eye on the F65 over stepped bands
        // and 12/16 fps. F65_STEPPED=1 brings back the whole-column stepping.
        let smooth = ProcessInfo.processInfo.environment["F65_STEPPED"] == nil
        frame = { t in
            if smooth {
                // Continuous flow: each column has its own hue, drifting every frame; hue snapped to
                // `waveHues` steps so neighbouring columns can share radio groups.
                return (0..<126).map { slot -> [UInt8] in
                    var h = Double(slot / 6) / 16 - t * speed / 16
                    h -= h.rounded(.down)
                    // No hue snapping unless F65_HUES is set: at most 16 colours (one per column) fit anyway.
                    if ProcessInfo.processInfo.environment["F65_HUES"] == nil { return liveHSV(h) }
                    return liveHSV((h * waveHues).rounded(.down) / waveHues)
                }
            }
            let shift = Int(t * speed)
            return (0..<126).map { slot -> [UInt8] in
                let col = ((slot / 6 - shift) % 16 + 16) % 16
                return liveHSV((Double(col) * waveHues / 16).rounded(.down) / waveHues)
            }
        }
    default:
        fputs("usage: f65 live [test | all <color> | keys k=color… [rest=color] | wave] [seconds]\n", stderr); exit(2)
    }
    print(secs.isFinite ? "Streaming for \(Int(secs)) s" : "Streaming — press Ctrl-C to stop")
    let start = Date()
    var fails = 0
    // Fixed-rate ticks (default 20/s, the rate picked on the F65); animation time is the wall clock.
    // With F65_STEPPED, use F65_FPS=24 so 8-column/s steps land exactly every 3rd tick.
    let env = ProcessInfo.processInfo.environment
    let fps = Double(env["F65_FPS"] ?? "") ?? 20
    let dup = Int(env["F65_DUP"] ?? "") ?? 1          // send each new frame this many times (loss cover)
    let debug = env["F65_DEBUG"] != nil
    var lastStat = Date()
    var replies: [String: Int] = [:]
    var tick = 0
    var maxLate = 0.0
    var lastSent: [[UInt8]] = []
    var lastSendTime = Date.distantPast
    var repeatsLeft = 0
    while Date().timeIntervalSince(start) < secs {
        // Send only when the picture changes, plus a keep-alive (the keyboard falls back to its saved
        // effect after ~1 s without frames). Radio budget on the F65 is roughly 70 reports/s.
        // Wall-clock time: ticks are aligned to the steps, and a slow send can't make the wave fall behind.
        let f = frame(Date().timeIntervalSince(start))
        if f != lastSent {
            repeatsLeft = dup
        } else if Date().timeIntervalSince(lastSendTime) >= 0.4 {
            repeatsLeft = max(repeatsLeft, 1)
        }
        if repeatsLeft > 0 {
            if !kb.sendLive(f, keys: keySlots) { fails += 1 }
            lastSent = f; lastSendTime = Date(); repeatsLeft -= 1
        }
        tick += 1
        let due = start.addingTimeInterval(Double(tick) / fps)
        maxLate = max(maxLate, -due.timeIntervalSinceNow * 1000)
        CFRunLoopRunInMode(.defaultMode, max(0.001, due.timeIntervalSinceNow), true)
        for r in kb.inbox { replies[String(format: "%02x", r.count > 1 ? r[1] : 0), default: 0] += 1 }
        kb.inbox.removeAll()
        if debug && Date().timeIntervalSince(lastStat) >= 1 {
            let st = liveStats
            print(String(format: "frames %d  avg %.0f B/frame  reports %d  send avg %.1f ms max %.1f ms  late max %.0f ms  replies %@",
                         st.frames, Double(st.bytes) / Double(max(st.frames, 1)), st.reports,
                         st.sendMs / Double(max(st.reports, 1)), st.maxSendMs, maxLate, replies.description))
            liveStats = LiveStats(); replies = [:]; lastStat = Date(); maxLate = 0
        }
    }
    if fails > 0 { fputs("\(fails) frames failed\n", stderr) }
}

// MARK: - Safe saving
// Every settings save goes through save(): the keyboard must answer first, nothing else may be streaming
// to it, and afterwards every byte that was meant to change is read back. A save that fails or doesn't
// verify is tried once more, then the previous contents are written back (and checked). Over the cable
// a block is a single report, so it's all-or-nothing; over 2.4G it is 10–36 acknowledged packets.
// (Only changed bytes are compared: some bytes, e.g. lighting offset 0x0e, change on their own.)

func appIsStreaming() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "F65Lighting"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

func save(_ kb: F65, _ cmd: UInt8, sub: UInt8 = 0, data new: [UInt8], previous old: [UInt8], backupFile: String) -> Bool {
    let readCmd = cmd | 0x40
    let route = kb.viaCable ? "the USB cable" : "2.4G"
    if appIsStreaming() {
        fputs("F65 Lighting is running and sending to the keyboard. Quit it (menu → Quit F65 Lighting) and retry. Nothing was saved.\n", stderr)
        return false
    }
    if cmd == 0x04 && (new.count != 128 || new[126] != 0x5A || new[127] != 0xA5) {
        fputs("Lighting block looks invalid (no 5a a5 end marker). Nothing was saved.\n", stderr); return false
    }
    if !kb.viaCable && kb.query(0x07)?.first != 1 {
        fputs("The keyboard isn't answering over 2.4G (asleep or out of range). Press a key and retry. Nothing was saved.\n", stderr)
        return false
    }
    let changed = (0..<min(new.count, old.count)).filter { new[$0] != old[$0] }
    let simulateFail = ProcessInfo.processInfo.environment["F65_TEST_VERIFY_FAIL"] != nil   // test the rollback path
    func holds(_ want: [UInt8]) -> Bool {
        guard let back = kb.query(readCmd, sub: sub, timeout: 3), back.count == want.count else { return false }
        return changed.allSatisfy { back[$0] == want[$0] }
    }
    for attempt in 1...2 {
        if kb.write(cmd, sub: sub, data: new), !simulateFail, holds(new) {
            print("saved over \(route) and verified (\(changed.count) byte\(changed.count == 1 ? "" : "s") changed)")
            return true
        }
        fputs("save attempt \(attempt) over \(route) failed or didn't verify\n", stderr)
    }
    fputs("rolling back to the previous settings…\n", stderr)
    for _ in 1...2 where kb.write(cmd, sub: sub, data: old) && holds(old) {
        fputs("rolled back: the keyboard is as it was before. Nothing was changed.\n", stderr)
        return false
    }
    fputs("ROLLBACK FAILED. Restore with:  ./f65 restore \(backupFile)   (ideally with the USB cable in wired mode)\n", stderr)
    return false
}
