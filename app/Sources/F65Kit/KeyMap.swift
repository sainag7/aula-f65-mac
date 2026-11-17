// Which key sits in which LED slot.
//
// 126 slots, slot = column * 6 + row (row 0 = hidden F-row, 1 = number row … 5 = bottom row).
// The keyboard's stored key map has 4 bytes per slot: `00 mods 00 usage` for normal keys,
// `0d 00 00 00` for Fn, all zero for an empty slot. Slot 0 is a hidden duplicate Esc.

import Foundation

public struct KeyMap {
    public static let slotCount = 126
    public static let byteCount = 504

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count >= KeyMap.byteCount else { return nil }
        self.bytes = Array(bytes.prefix(KeyMap.byteCount))
    }

    public func entry(_ slot: Int) -> [UInt8] { Array(bytes[(slot * 4)..<(slot * 4 + 4)]) }

    /// Slots that hold a visible key (non-empty entry, not slot 0, not the hidden F-row).
    public var litSlots: [Int] {
        (1..<KeyMap.slotCount).filter { $0 % 6 != 0 && entry($0) != [0, 0, 0, 0] }
    }

    /// Slots holding the key with this name ("w", "esc", "lshift", "fn", "slot42", …).
    public func slots(for name: String) -> [Int]? {
        let n = name.lowercased()
        if n.hasPrefix("slot"), let s = Int(n.dropFirst(4)), (1..<KeyMap.slotCount).contains(s) { return [s] }
        guard let e = KeyMap.entry(forName: n) else { return nil }
        let found = (1..<KeyMap.slotCount).filter { entry($0) == e }
        return found.isEmpty ? nil : found
    }

    /// Key name → 4-byte key-map entry (same as `keyCode()` in wired.swift, plus a few aliases).
    public static func entry(forName raw: String) -> [UInt8]? {
        let n = raw.lowercased()
        let mods: [String: UInt8] = [
            "lctrl": 0x01, "ctrl": 0x01, "control": 0x01, "lshift": 0x02, "shift": 0x02, "lalt": 0x04, "alt": 0x04,
            "option": 0x04, "lopt": 0x04, "lcmd": 0x08, "cmd": 0x08, "command": 0x08, "win": 0x08,
            "rctrl": 0x10, "rshift": 0x20, "ralt": 0x40, "ropt": 0x40, "rcmd": 0x80, "rwin": 0x80,
        ]
        if let m = mods[n] { return [0, m, 0, 0] }
        if n == "fn" { return [0x0D, 0, 0, 0] }
        let named: [String: UInt8] = [
            "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29, "backspace": 0x2A, "bksp": 0x2A,
            "tab": 0x2B, "space": 0x2C, "-": 0x2D, "minus": 0x2D, "=": 0x2E, "equal": 0x2E, "equals": 0x2E,
            "[": 0x2F, "]": 0x30, "\\": 0x31, "backslash": 0x31, "#": 0x32, ";": 0x33, "semicolon": 0x33,
            "'": 0x34, "quote": 0x34, "`": 0x35, "grave": 0x35, ",": 0x36, "comma": 0x36, ".": 0x37,
            "period": 0x37, "/": 0x38, "slash": 0x38, "caps": 0x39, "capslock": 0x39,
            "delete": 0x4C, "del": 0x4C, "pgup": 0x4B, "pageup": 0x4B, "pgdn": 0x4E, "pagedown": 0x4E,
            "end": 0x4D, "home": 0x4A, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        ]
        if let u = named[n] { return [0, 0, 0, u] }
        if n.hasPrefix("f"), let k = Int(n.dropFirst()), (1...12).contains(k) { return [0, 0, 0, UInt8(0x3A + k - 1)] }
        if n.count == 1, let c = n.unicodeScalars.first {
            if ("a"..."z").contains(n) { return [0, 0, 0, UInt8(c.value - 97 + 0x04)] }
            if n == "0" { return [0, 0, 0, 0x27] }
            if ("1"..."9").contains(n) { return [0, 0, 0, UInt8(c.value - 49 + 0x1E)] }
        }
        return nil
    }

    // MARK: Fallback and cache

    /// Factory base layer as read from this keyboard on 2026-11-17. Used when the map can't be read
    /// and nothing is cached yet. Both transports now share the snapshot map.
    public static let fallback: KeyMap = {
        let hex = "00000029000000290000002b0000003900020000000100000000003a0000001e00000014000000040000001d00080000"
            + "0000003b0000001f0000001a000000160000001b000400000000003c00000020000000080000000700000006000000"
            + "000000003d00000021000000150000000900000019000000000000003e00000022000000170000000a000000050000"
            + "002c0000003f000000230000001c0000000b00000011000000000000004000000024000000180000000d0000001000"
            + "00000000000041000000250000000c0000000e00000036000000000000004200000026000000120000000f00000037"
            + "0d000000000000430000002700000013000000330000003800100000000000440000002d0000002f00000034000000"
            + "0000000000000000450000002e00000030000000320000000000000000000000000000002a00000031000000280020"
            + "00000000005000000000000000000000000000000000000000520000005100000000000000"
            + "4c0000004b0000004e0000004d0000004f"
        var b = KeyMap.parseHex(hex)
        b += [UInt8](repeating: 0, count: max(0, KeyMap.byteCount - b.count))
        return KeyMap(bytes: b)!
    }()

    public static func parseHex(_ s: String) -> [UInt8] {
        let chars = Array(s.filter { $0.isHexDigit })
        return stride(from: 0, to: chars.count - 1, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
    }

    public static var cacheURL: URL { AppPaths.supportDir.appendingPathComponent("keymap.hex") }

    public static func loadCached() -> KeyMap? {
        guard let s = try? String(contentsOf: cacheURL, encoding: .utf8) else { return nil }
        return KeyMap(bytes: parseHex(s))
    }

    public func saveToCache() {
        let s = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        try? s.write(to: KeyMap.cacheURL, atomically: true, encoding: .utf8)
    }
}

public enum AppPaths {
    public static var supportDir: URL {
        if let path = ProcessInfo.processInfo.environment["F65_DATA_DIR"] { return URL(fileURLWithPath:path) }
        if ProcessInfo.processInfo.environment["F65_MOCK"] == "1" { return FileManager.default.temporaryDirectory.appendingPathComponent("F65Lighting-Mock") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("F65Lighting", isDirectory: true)
    }
    public static var layoutURL: URL { supportDir.appendingPathComponent("layout.json") }
}
