// Physical key positions, for animated live backgrounds.
//
// Ported from the keyboard preview (`Resources/keyboard/index.html`, ROWS/KEYS) so the streamed
// effects line up with what the preview draws. Units are key widths: `cx` is the key centre from
// the left edge, `cy` the row centre (row 0 = number row … 4 = bottom row).

import Foundation

public struct KeyPosition: Equatable {
    public let id: String
    public let index: Int       // position in PhysicalKey.ids (same order as the preview's KEYS)
    public let slot: Int        // LED slot
    public let cx: Double
    public let cy: Double
}

public enum KeyGeometry {
    /// Widths that aren't 1u; a 0.5u gap sits before the arrow cluster's "left" key.
    static let widths: [String: Double] = [
        "bksp": 2, "tab": 1.5, "bslash": 1.5, "caps": 1.75, "enter": 2.25, "lshift": 2.25, "rshift": 1.75,
        "lctrl": 1.25, "lwin": 1.25, "lalt": 1.25, "space": 6.25, "fn": 1.25, "rctrl": 1.25,
    ]
    static let gapBefore: [String: Double] = ["left": 0.5]

    public static let keys: [KeyPosition] = {
        var out: [KeyPosition] = []
        var index = 0
        for (y, row) in PhysicalKey.rows.enumerated() {
            var x = 0.0
            for id in row {
                x += gapBefore[id] ?? 0
                let w = widths[id] ?? 1
                out.append(KeyPosition(id: id, index: index, slot: PhysicalKey.slots[id]!, cx: x + w / 2, cy: Double(y) + 0.5))
                x += w
                index += 1
            }
        }
        return out
    }()

    /// Same pseudo-random values as the preview (`rnd`, `rnd2`), so twinkles land on the same keys.
    public static let rnd: [Double] = keys.map { frac(sin(Double($0.index) * 12.9898) * 43758.5453) }
    public static let rnd2: [Double] = keys.map { frac(sin(Double($0.index) * 78.233 + 1) * 12345.678) }

    /// Boustrophedon order (left→right, then right→left on the next row), used by Snake.
    public static let snakeOrder: [String: Int] = {
        var order: [KeyPosition] = []
        for y in 0..<PhysicalKey.rows.count {
            var row = keys.filter { Int($0.cy) == y }.sorted { $0.cx < $1.cx }
            if y % 2 == 1 { row.reverse() }
            order += row
        }
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, $0) })
    }()

    static func frac(_ x: Double) -> Double { x - x.rounded(.down) }
}
