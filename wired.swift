// wired — READ-ONLY probe for the AULA F65 in USB-cable mode (258A:010C).
// Protocol (driver class CDevG5KB): 520-byte feature report, ID 0x06.
//   [0]=0x06 [1]=cmd [2]=sub [3]=0 [4]=page count [5]=page index [6..7]=length LE [8..]=data (≤512)
// Read = send header with cmd|0x80 via SetReport(feature), then GetReport(feature) returns data at [8..].
// Write cmds: 03 matrix, 04 LED, 05 macro, 06 game, 0A palette, 0B ?, 11 reset.  This tool never writes.

import Foundation
import IOKit.hid

func hex(_ b: ArraySlice<UInt8>) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x258A, kIOHIDProductIDKey: 0x010C] as CFDictionary)
guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
      let dev = set.first(where: { (IOHIDDeviceGetProperty($0, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? 0) >= 520 }) else {
    fputs("Wired F65 (258A:010C) not found. Plug in the cable and switch to wired mode.\n", stderr); exit(1)
}
guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    fputs("Could not open the device (Input Monitoring permission?).\n", stderr); exit(1)
}

/// Read `length` bytes of block `cmd` (write-cmd number, e.g. 0x04), page by page.
func read(_ cmd: UInt8, sub: UInt8 = 0, length: Int) -> [UInt8]? {
    precondition(cmd < 0x80)
    let pages = (length + 511) / 512
    var out: [UInt8] = []
    for page in 0..<pages {
        let n = min(512, length - page * 512)
        var p = [UInt8](repeating: 0, count: 520)
        p[0] = 0x06; p[1] = cmd | 0x80; p[2] = sub; p[3] = 0
        p[4] = UInt8(pages); p[5] = UInt8(page); p[6] = UInt8(n & 0xFF); p[7] = UInt8(n >> 8)
        var ok = false
        for _ in 0..<3 {
            let r1 = p.withUnsafeBufferPointer { IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 6, $0.baseAddress!, 520) }
            if r1 != kIOReturnSuccess { usleep(70_000); continue }
            usleep(20_000)
            var buf = [UInt8](repeating: 0, count: 520)
            var len = CFIndex(520)
            let r2 = buf.withUnsafeMutableBufferPointer { IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 6, $0.baseAddress!, &len) }
            if r2 != kIOReturnSuccess { usleep(70_000); continue }
            if CommandLine.arguments.contains("-v") { print("  << hdr \(hex(buf[0..<8]))") }
            out += buf[8..<(8 + n)]
            ok = true; break
        }
        if !ok { fputs("read of cmd 0x\(String(cmd, radix: 16)) page \(page) failed\n", stderr); return nil }
    }
    return out
}

func dump(_ title: String, _ d: [UInt8]?) {
    print("\n== \(title)")
    guard let d = d else { print("   (failed)"); return }
    for off in stride(from: 0, to: d.count, by: 16) {
        print(String(format: "   %04x: ", off) + hex(d[off..<min(off + 16, d.count)]))
    }
}

// MARK: - Live per-key lighting (direct mode, nothing stored on the keyboard)
// Frame = one feature report: 06 08 00 00 01 00 7a 01 + 126 × (R,G,B), slot = column*6 + row.
// Must be re-sent continuously (~20 fps); the keyboard returns to its saved effect ~1 s after frames stop.
// Method from github.com/Itzadetunji/aula-f75-mac-driver (same Sinowealth 258A:010C protocol).

func sendFrame(_ colors: [[UInt8]]) -> Bool {
    var p = [UInt8](repeating: 0, count: 520)
    p[0] = 0x06; p[1] = 0x08; p[4] = 0x01; p[6] = 0x7A; p[7] = 0x01
    for (i, c) in colors.prefix(126).enumerated() { p[8 + i * 3] = c[0]; p[9 + i * 3] = c[1]; p[10 + i * 3] = c[2] }
    return p.withUnsafeBufferPointer { IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 6, $0.baseAddress!, 520) } == kIOReturnSuccess
}

func stream(seconds: Double, _ frame: (Double) -> [[UInt8]]) {
    let start = Date()
    var failures = 0
    while true {
        let t = Date().timeIntervalSince(start)
        if t >= seconds { break }
        if !sendFrame(frame(t)) { failures += 1 }
        usleep(50_000)   // 20 fps — faster starves the keyboard's key scanning
    }
    if failures > 0 { fputs("\(failures) frames failed\n", stderr) }
}

func color(_ s: String) -> [UInt8]? {
    let names: [String: [UInt8]] = ["red": [255, 0, 0], "green": [0, 255, 0], "blue": [0, 0, 255], "yellow": [255, 200, 0],
        "purple": [160, 0, 255], "cyan": [0, 255, 255], "white": [255, 255, 255], "orange": [255, 80, 0], "pink": [255, 0, 120], "off": [0, 0, 0]]
    if let c = names[s.lowercased()] { return c }
    let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard h.count == 6, let x = UInt32(h, radix: 16) else { return nil }
    return [UInt8(x >> 16 & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF)]
}

let a = Array(CommandLine.arguments.dropFirst()).filter { $0 != "-v" }

// wired effect <1-18|fixed|neon>: change only byte 0x0a of the 128-byte settings page over the cable.
if a.first == "effect" {
    let names = ["fixed": 1, "breathing": 2, "rainbow": 3, "neon": 11]
    guard a.count == 2, let e = Int(a[1]) ?? names[a[1].lowercased()], (1...18).contains(e) else {
        fputs("usage: wired effect <1-18 | fixed | breathing | rainbow | neon>\n", stderr); exit(2)
    }
    guard var page = read(0x04, length: 128), page.count == 128, page[126] == 0x5A, page[127] == 0xA5 else {
        fputs("could not read a valid settings page; not writing\n", stderr); exit(1)
    }
    print("effect \(page[0x0A]) → \(e)")
    page[0x0A] = UInt8(e)
    var p = [UInt8](repeating: 0, count: 520)
    p[0] = 0x06; p[1] = 0x04; p[4] = 0x01; p[6] = 0x80; p[7] = 0x00
    p.replaceSubrange(8..<136, with: page)
    let r = p.withUnsafeBufferPointer { IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 6, $0.baseAddress!, 520) }
    guard r == kIOReturnSuccess else { fputs("write failed\n", stderr); exit(1) }
    usleep(100_000)
    if let back = read(0x04, length: 128), back == page { print("written and verified") } else { print("written, but read-back differs") }
    exit(0)
}

if a.first == "live" {
    let mode = a.count > 1 ? a[1] : "test"
    switch mode {
    case "test":
        let secs = a.count > 2 ? Double(a[2]) ?? 15 : 15
        print("Streaming row test for \(Int(secs)) s: number row red, Q row green, A row blue, Z row yellow, bottom row white")
        let rows: [[UInt8]] = [[0, 0, 0], [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 200, 0], [255, 255, 255]]
        stream(seconds: secs) { _ in (0..<126).map { rows[$0 % 6] } }
    case "all":
        guard a.count > 2, let c = color(a[2]) else { fputs("usage: wired live all <color|#rrggbb> [seconds]\n", stderr); exit(2) }
        let secs = a.count > 3 ? Double(a[3]) ?? 15 : 15
        print("Streaming \(a[2]) for \(Int(secs)) s")
        stream(seconds: secs) { _ in Array(repeating: c, count: 126) }
    case "keys":
        // wired live keys w=red a=red s=red d=red rest=off [seconds]
        guard let map = read(0x03, length: 504) else { fputs("could not read key map\n", stderr); exit(1) }
        var rest: [UInt8] = [0, 0, 0]
        var frame = [[UInt8]](repeating: [0, 0, 0], count: 126)
        var secs = Double.infinity
        var assigned: [(Int, [UInt8])] = []
        for arg in a.dropFirst(2) {
            if let s = Double(arg) { secs = s; continue }
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let c = color(kv[1]) else { fputs("bad argument '\(arg)' (use key=color)\n", stderr); exit(2) }
            if kv[0].lowercased() == "rest" { rest = c; continue }
            guard let e = keyCode(kv[0]) else { fputs("unknown key '\(kv[0])'\n", stderr); exit(2) }
            let slots = (1..<126).filter { Array(map[($0 * 4)..<($0 * 4 + 4)]) == e }
            guard !slots.isEmpty else { fputs("key '\(kv[0])' not on the keyboard\n", stderr); exit(2) }
            slots.forEach { assigned.append(($0, c)) }
        }
        frame = frame.map { _ in rest }
        for (s, c) in assigned { frame[s] = c }
        print("Streaming \(assigned.count) coloured keys" + (secs.isFinite ? " for \(Int(secs)) s" : " — press Ctrl-C to stop"))
        stream(seconds: secs) { _ in frame }
    case "wave":
        let secs = a.count > 2 ? Double(a[2]) ?? .infinity : .infinity
        print("Rainbow wave" + (secs.isFinite ? " for \(Int(secs)) s" : " — press Ctrl-C to stop"))
        stream(seconds: secs) { t in
            (0..<126).map { slot in
                let hue = (Double(slot / 6) / 16.0 - t * 0.25).truncatingRemainder(dividingBy: 1) + 1
                return hsv(hue.truncatingRemainder(dividingBy: 1))
            }
        }
    default:
        fputs("usage: wired live [test | all <color> | keys k=color… [rest=color] | wave] [seconds]\n", stderr); exit(2)
    }
    exit(0)
}

func hsv(_ h: Double) -> [UInt8] {
    let x = h * 6, i = Int(x) % 6, f = x - Double(Int(x))
    let q = UInt8((1 - f) * 255), t = UInt8(f * 255)
    switch i {
    case 0: return [255, t, 0]
    case 1: return [q, 255, 0]
    case 2: return [0, 255, t]
    case 3: return [0, q, 255]
    case 4: return [t, 0, 255]
    default: return [255, 0, q]
    }
}

/// Key name → 4-byte key-map entry (same format as the stored key matrix).
func keyCode(_ raw: String) -> [UInt8]? {
    let n = raw.lowercased()
    let mods: [String: UInt8] = ["lctrl": 0x01, "ctrl": 0x01, "lshift": 0x02, "shift": 0x02, "lalt": 0x04, "alt": 0x04,
        "lcmd": 0x08, "cmd": 0x08, "win": 0x08, "rctrl": 0x10, "rshift": 0x20, "ralt": 0x40, "rcmd": 0x80]
    if let m = mods[n] { return [0, m, 0, 0] }
    if n == "fn" { return [0x0D, 0, 0, 0] }
    let named: [String: UInt8] = ["enter": 0x28, "esc": 0x29, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
        "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31, "#": 0x32, ";": 0x33, "'": 0x34, "`": 0x35,
        ",": 0x36, ".": 0x37, "/": 0x38, "caps": 0x39, "capslock": 0x39, "delete": 0x4C, "del": 0x4C,
        "pgup": 0x4B, "pgdn": 0x4E, "end": 0x4D, "home": 0x4A, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52]
    if let u = named[n] { return [0, 0, 0, u] }
    if n.count == 1, let c = n.unicodeScalars.first {
        if ("a"..."z").contains(n) { return [0, 0, 0, UInt8(c.value - 97 + 0x04)] }
        if n == "0" { return [0, 0, 0, 0x27] }
        if ("1"..."9").contains(n) { return [0, 0, 0, UInt8(c.value - 49 + 0x1E)] }
    }
    return nil
}
if a.count >= 2, let c = UInt8(a[0], radix: 16), let n = Int(a[1]) {
    let sub = a.count > 2 ? UInt8(a[2]) ?? 0 : 0
    dump("cmd 0x\(String(c, radix: 16)) sub \(sub), \(n) bytes", read(c, sub: sub, length: n))
} else {
    dump("04 LED (512)", read(0x04, length: 512))
    dump("0A palette (512)", read(0x0A, length: 512))
    dump("03 key matrix layer 0 (512)", read(0x03, length: 512))
}
