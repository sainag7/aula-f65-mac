// Live-lighting packet encoders. Pure functions, no I/O.

import Foundation

public enum CableProtocol {
    public static let reportSize = 520
    public static let reportID: UInt8 = 6

    /// One feature report: `06 08 00 00 01 00 7a 01` + 126 × (R,G,B), rest zero.
    public static func frame(_ colors: [RGB]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: reportSize)
        p[0] = 0x06; p[1] = 0x08; p[4] = 0x01; p[6] = 0x7A; p[7] = 0x01
        for (i, c) in colors.prefix(KeyMap.slotCount).enumerated() {
            p[8 + i * 3] = c.r; p[9 + i * 3] = c.g; p[10 + i * 3] = c.b
        }
        return p
    }

    /// Key-map read request (cmd 0x03 | 0x80, one page, 504 bytes); reply data starts at byte 8.
    public static let keyMapRequest: [UInt8] = {
        var p = [UInt8](repeating: 0, count: reportSize)
        p[0] = 0x06; p[1] = 0x83; p[4] = 0x01; p[6] = 0xF8; p[7] = 0x01
        return p
    }()
}

public enum ReceiverProtocol {
    public static let reportID: UInt8 = 0x13
    /// Confirmed on the F65: 7-report frames display correctly (the F75 project capped at 6).
    /// The vendor driver's SetRealData has no fixed cap; 12 keeps frames short at 20 fps.
    public static let maxReports = 12
    public static let bytesPerReport = 14
    public static var maxBytes: Int { maxReports * bytesPerReport }   // 84

    public static func checksum(_ p: [UInt8]) -> UInt8 { UInt8(p[0..<19].reduce(0) { ($0 + Int($1)) & 0xFF }) }

    /// Quantise one channel to `levels` evenly spaced values (4 → 0/85/170/255).
    public static func quantise(_ v: UInt8, levels: Int) -> UInt8 {
        let step = 255.0 / Double(levels - 1)
        return UInt8(min(255, (Double(v) / step).rounded() * step))
    }

    public static func quantise(_ c: RGB, levels: Int) -> RGB {
        let q = RGB(r: quantise(c.r, levels: levels), g: quantise(c.g, levels: levels), b: quantise(c.b, levels: levels))
        if q.isBlack && !c.isBlack {
            // Keep dim colours visible: lowest non-zero level on the strongest channel(s).
            let top = max(c.r, c.g, c.b), lo = UInt8(255.0 / Double(levels - 1))
            return RGB(r: c.r == top ? lo : 0, g: c.g == top ? lo : 0, b: c.b == top ? lo : 0)
        }
        return q
    }

    /// Colour-group stream `R G B count led1 led2 …`, at most `maxBytes`. Black LEDs are left out
    /// (unlisted LEDs go dark). Exact colours first (a wave has ≤ 16, one per column, so it fits);
    /// then coarser quantisation, then the smallest groups get merged into the nearest colour.
    public static func stream(_ colors: [RGB], slots: [Int]) -> [UInt8] {
        var groups: [(color: RGB, leds: [Int])] = []
        for levels in [0, 4, 3, 2] {   // 0 = exact colours
            var index: [RGB: Int] = [:]
            groups = []
            for s in slots where s < colors.count && !colors[s].isBlack {
                let q = levels == 0 ? colors[s] : quantise(colors[s], levels: levels)
                if let i = index[q] { groups[i].leds.append(s) } else { index[q] = groups.count; groups.append((q, [s])) }
            }
            if size(groups) <= maxBytes { break }
        }
        while size(groups) > maxBytes && groups.count > 1 {
            groups.sort(by: stableOrder)
            let small = groups.removeLast()
            let j = groups.indices.min { groups[$0].color.distance(to: small.color) < groups[$1].color.distance(to: small.color) }!
            groups[j].leds += small.leds
        }
        if groups.count == 1 && size(groups) > maxBytes {
            groups[0].leds = Array(groups[0].leds.prefix(maxBytes - 4))   // can't happen with the F65's 68 keys
        }
        if groups.isEmpty {
            return [0, 0, 0, 1, UInt8(slots.first ?? 1)]   // explicit "all dark"
        }
        groups.sort(by: stableOrder)
        return groups.flatMap { [$0.color.r, $0.color.g, $0.color.b, UInt8($0.leds.count)] + $0.leds.map { UInt8($0) } }
    }

    /// Bigger groups first; ties broken by colour so the order never changes between frames
    /// (an unstable order made keys flicker on the F65).
    private static func stableOrder(_ a: (color: RGB, leds: [Int]), _ b: (color: RGB, leds: [Int])) -> Bool {
        if a.leds.count != b.leds.count { return a.leds.count > b.leds.count }
        return (a.color.r, a.color.g, a.color.b) < (b.color.r, b.color.g, b.color.b)
    }

    private static func size(_ g: [(color: RGB, leds: [Int])]) -> Int { g.reduce(0) { $0 + 4 + $1.leds.count } }

    /// Split the stream into 20-byte output reports: `13 88 total seq 0x10+n data… checksum`.
    public static func reports(_ colors: [RGB], slots: [Int]) -> [[UInt8]] {
        let data = stream(colors, slots: slots)
        let chunks = stride(from: 0, to: data.count, by: bytesPerReport).map {
            Array(data[$0..<min($0 + bytesPerReport, data.count)])
        }
        return chunks.enumerated().map { seq, chunk in
            var r = [UInt8](repeating: 0, count: 20)
            r[0] = reportID; r[1] = 0x88; r[2] = UInt8(chunks.count); r[3] = UInt8(seq); r[4] = UInt8(0x10 + chunk.count)
            r.replaceSubrange(5..<(5 + chunk.count), with: chunk)
            r[19] = checksum(r)
            return r
        }
    }
}
