import Foundation
public enum Mode: String, CaseIterable {
    case off, solid, wave, custom
    public var title: String {
        switch self {
        case .off: return "Off"
        case .solid: return "Solid colour"
        case .wave: return "Rainbow wave"
        case .custom: return "Custom layout"
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
        let resolved = settings.layout.resolve(map)
        var frame = (0..<126).map { slot -> RGB in
            switch settings.mode {
            case .off: return .black
            case .solid: return settings.color
            case .custom: return resolved.frame[slot]
            case .wave: return RGB(hue:Double(slot/6)/16-time*(receiver ? 0.5 : 0.25))
            }
        }.map { $0.scaled(settings.brightness) }
        // Physical LEDs don't disappear when a key is disabled. Always mask the hidden F-row.
        let visible = Set(PhysicalKey.slots.values)
        for s in frame.indices where !visible.contains(s) { frame[s] = .black }
        return frame
    }
}
