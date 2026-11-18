// Animated live backgrounds: Swift ports of the preview's onboard-effect approximations
// (`lightFor()` in Resources/keyboard/index.html). The keyboard can't run its own effect under
// host-sent colours, so the app draws these itself and layers per-key colours on top.

import Foundation

public enum Backgrounds {
    /// Effect numbers (onboard numbering) that can be drawn without keystroke input.
    /// Reactive ones — 4 Flash away, 7 Ripples, 9 Shadow, 12 Reaction — need system-wide key events.
    public static let available = [16, 10, 2, 3, 5, 6, 8, 11, 13, 14, 15, 17, 18]

    /// Effects whose colour comes from the animation itself (a chosen colour is ignored).
    public static let alwaysMulticolour: Set<Int> = [3, 6, 11]

    public static func name(_ effect: Int) -> String {
        (1...LightingBlock.names.count).contains(effect) ? LightingBlock.names[effect - 1] : "Effect \(effect)"
    }

    /// Speed steps, same as the preview (`SPD`).
    static let speeds: [Double] = [0.35, 0.6, 1, 1.5, 2.2]

    /// One frame of `effect` for every physical key, indexed by LED slot (126 entries, hidden slots black).
    public static func frame(effect: Int, time: Double, speed: Int, multicolour: Bool, color: RGB) -> [RGB] {
        var frame = [RGB](repeating: .black, count: KeyMap.slotCount)
        let t = time * speeds[max(0, min(speeds.count - 1, speed))]
        for k in KeyGeometry.keys {
            frame[k.slot] = colour(k, effect: effect, t: t, multicolour: multicolour, color: color)
        }
        return frame
    }

    static func colour(_ k: KeyPosition, effect: Int, t T: Double, multicolour multi: Bool, color: RGB) -> RGB {
        var i = 1.0
        var hue: Double? = multi ? k.cx * 22 + T * 30 : nil   // degrees; nil = use the chosen colour
        let rnd = KeyGeometry.rnd[k.index], rnd2 = KeyGeometry.rnd2[k.index]
        switch effect {
        case 2:  i = 0.5 - 0.5 * cos(T * 2)                                            // Breathing
        case 3:  hue = k.cx * 24 - T * 90                                               // Rainbow
        case 5:                                                                          // Raindrops
            let ph = (T * 0.5 + rnd * 3).truncatingRemainder(dividingBy: 3)
            i = max(0, 1 - ph * 1.6)
            if multi { hue = rnd2 * 360 + (T * 0.5 + rnd * 3).rounded(.down) * 97 }
        case 6:  hue = atan2(k.cy - 2.5, (k.cx - 8) / 2) * 57.3 + T * 120              // Rainbow wheel
        case 8:                                                                          // Stars
            i = pow(max(0, sin(T * 1.4 + rnd * 6.28)), 10)
            if multi { hue = rnd2 * 360 }
        case 10:                                                                         // Snake
            let n = Double(KeyGeometry.keys.count)
            let pos = Double(KeyGeometry.snakeOrder[k.id] ?? 0)
            let head = (T * 9).truncatingRemainder(dividingBy: n)
            let d = (head - pos + n).truncatingRemainder(dividingBy: n)
            i = d < 7 ? 1 - d / 7 : 0
            if multi { hue = pos * 8 }
        case 11: hue = T * 45                                                            // Neon
        case 13: i = 0.5 + 0.5 * sin(k.cx * 0.7 - T * 3.2)                               // Sine wave
        case 14:                                                                         // Scanning
            let bar = 8 + 8.2 * sin(T * 1.6)
            i = max(0, 1 - abs(k.cx - bar) / 1.6)
        case 15:                                                                         // Windmill
            let a = atan2(k.cy - 2.5, (k.cx - 8) / 2.2)
            i = pow(max(0, cos(2 * (a - T * 1.6))), 3)
        case 16:                                                                         // Waterfall
            if multi { hue = k.cy * 55 - T * 130 }
            i = 0.65 + 0.35 * sin(k.cy * 1.3 - T * 4)
        case 17:                                                                         // Blossom
            let d = hypot((k.cx - 8) / 1.6, k.cy - 2.5)
            if multi { hue = d * 40 - T * 90 }
            i = 0.55 + 0.45 * sin(d * 1.4 - T * 3)
        case 18:                                                                         // Storm
            let f = (T * 2.4).rounded(.down), fr = T * 2.4 - f
            let x = KeyGeometry.frac(sin(((k.cx / 2.5).rounded(.down) * 7 + f * 13) * 12.9) * 9999)
            let strike = x > 0.55 ? max(pow(1 - fr, 2), fr > 0.25 && fr < 0.45 ? 0.8 : 0) : 0
            i = max(0.22, strike)
            if multi { hue = 200 + x * 80 }
        default: break                                                                   // 1 Fixed
        }
        let base = hue.map { RGB(hue: $0 / 360) } ?? color
        return base.scaled(max(0, min(1, i)))
    }
}
