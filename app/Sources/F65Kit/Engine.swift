import Foundation
public enum Mode: String, CaseIterable {
    case off, solid, wave, custom, dark, effect
    public var title: String {
        switch self {
        case .off: return "Off"
        case .solid: return "Solid colour"
        case .wave: return "Rainbow wave"
        case .custom: return "Custom layout"
        case .dark: return "Dark"
        case .effect: return "Effect"
        }
    }
}

public enum ConnectionPref: String, CaseIterable {
    case auto, cable, receiver
    public var title: String {
        switch self {
        case .auto: return "Automatic (prefer cable)"
        case .cable: return "USB cable only"
        case .receiver: return "2.4G receiver only"
        }
    }
}

public struct Settings {
    public init() {}
    public var mode: Mode = .wave
    public var color = RGB(r: 160, g: 0, b: 255)
    public var brightness = 1.0
    public var paused = false
    public var pref: ConnectionPref = .auto
    public var layout = LayoutSpec()
    /// Background animation for `.effect` (onboard numbering, see `Backgrounds.available`).
    public var effect = 16
    public var effectSpeed = 2            // 0–4
    public var effectMulticolour = true   // otherwise uses `color`
    /// Per-key colours (PhysicalKey ids) drawn on top of whatever the mode draws.
    public var keyColors: [String: RGB] = [:]
}

public struct EngineStatus: Equatable {
    public init() {}
    public var link: LinkKind?
    public var cablePresent = false
    public var receiverPresent = false
    public var streaming = false
    public var message: String?            // error / hint
    public var unknownKeys: [String] = []
    public var keyMapSource = "built-in"
}


public enum FrameRenderer {
    public static func render(_ settings: Settings, map: KeyMap, time: Double, receiver: Bool) -> [RGB] {
        var frame: [RGB]
        switch settings.mode {
        case .off, .dark: frame = [RGB](repeating: .black, count: KeyMap.slotCount)
        case .solid: frame = [RGB](repeating: settings.color, count: KeyMap.slotCount)
        case .custom: frame = settings.layout.resolve(map).frame
        case .wave: frame = (0..<KeyMap.slotCount).map { RGB(hue: Double($0 / 6) / 16 - time * (receiver ? 0.5 : 0.25)) }
        case .effect:
            frame = Backgrounds.frame(effect: settings.effect, time: time, speed: settings.effectSpeed,
                                      multicolour: settings.effectMulticolour, color: settings.color)
        }
        // Per-key colours sit on top of every mode.
        for slot in pinnedSlots(settings) { frame[slot] = keyColor(settings, slot: slot) }
        frame = frame.map { $0.scaled(settings.brightness) }
        // Physical LEDs don't disappear when a key is disabled. Always mask the hidden F-row.
        let visible = Set(PhysicalKey.slots.values)
        for s in frame.indices where !visible.contains(s) { frame[s] = .black }
        return frame
    }

    /// LED slots that carry a per-key colour. The 2.4G encoder keeps these exact.
    public static func pinnedSlots(_ settings: Settings) -> Set<Int> {
        Set(settings.keyColors.keys.compactMap { PhysicalKey.slots[$0] })
    }

    static func keyColor(_ settings: Settings, slot: Int) -> RGB {
        settings.keyColors.first { PhysicalKey.slots[$0.key] == slot }?.value ?? .black
    }
}
