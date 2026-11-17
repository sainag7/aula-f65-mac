// Key name tables ported verbatim from f65.swift, with Mac display names.
import Foundation
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

func describeKey(_ e: [UInt8]) -> String {
    let raw = hex(e)
    switch e[0] {
    case 0x00:
        var parts: [String] = []
        let mods = ["LCtrl", "LShift", "L⌥ Option", "L⌘ Cmd", "RCtrl", "RShift", "R⌥ Option", "R⌘ Cmd"]
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

