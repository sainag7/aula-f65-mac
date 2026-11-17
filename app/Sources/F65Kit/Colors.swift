// Colour helpers shared by the renderer and the UI.

import Foundation

public struct RGB: Hashable {
    public var r: UInt8, g: UInt8, b: UInt8

    public static let black = RGB(r: 0, g: 0, b: 0)

    public var isBlack: Bool { r == 0 && g == 0 && b == 0 }

    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }

    public func scaled(_ f: Double) -> RGB {
        if f >= 0.999 { return self }
        func s(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) * f).rounded()))) }
        return RGB(r: s(r), g: s(g), b: s(b))
    }

    /// Squared distance, used to merge colour groups for the 2.4G stream.
    public func distance(to o: RGB) -> Int {
        let dr = Int(r) - Int(o.r), dg = Int(g) - Int(o.g), db = Int(b) - Int(o.b)
        return dr * dr + dg * dg + db * db
    }

    /// Accepts "#rrggbb", "rrggbb", "#rgb" or a colour name.
    public init?(string raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let names: [String: (UInt8, UInt8, UInt8)] = [
            "red": (255, 0, 0), "green": (0, 255, 0), "blue": (0, 0, 255), "yellow": (255, 200, 0),
            "purple": (160, 0, 255), "magenta": (255, 0, 255), "cyan": (0, 255, 255), "white": (255, 255, 255),
            "orange": (255, 80, 0), "pink": (255, 0, 120), "off": (0, 0, 0), "black": (0, 0, 0),
        ]
        if let c = names[s] { self.init(r: c.0, g: c.1, b: c.2); return }
        var h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let x = UInt32(h, radix: 16) else { return nil }
        self.init(r: UInt8(x >> 16 & 0xFF), g: UInt8(x >> 8 & 0xFF), b: UInt8(x & 0xFF))
    }

    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// Fully saturated hue, h in [0, 1).
    public init(hue h: Double) {
        var h = h - h.rounded(.down)
        if h >= 1 { h = 0 }
        let x = h * 6, i = Int(x) % 6, f = x - Double(Int(x))
        let q = UInt8((1 - f) * 255), t = UInt8(f * 255)
        switch i {
        case 0: self.init(r: 255, g: t, b: 0)
        case 1: self.init(r: q, g: 255, b: 0)
        case 2: self.init(r: 0, g: 255, b: t)
        case 3: self.init(r: 0, g: q, b: 255)
        case 4: self.init(r: t, g: 0, b: 255)
        default: self.init(r: 255, g: 0, b: q)
        }
    }
}
