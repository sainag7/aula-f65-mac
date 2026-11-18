// Looks: one idea for everything the keyboard can show.
//
// A keyboard Look is an onboard effect with that effect's brightness, speed and colour (and optionally the side
// lights). It is written to the lighting block (04) and keeps working with the app closed.
// An app Look is drawn by this app and streamed (background + per-key colours). Nothing is written for it.

import Foundation

public struct Look: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case keyboard, app }

    public var id: String
    public var name: String
    public var kind: Kind
    public var favourite = false
    public var builtIn = false

    // Keyboard looks (lighting block)
    public var effect = 1                 // 1–18, onboard numbering
    public var brightness = 4             // 0–4
    public var speed = 2                  // 0–4, direction unconfirmed
    public var colour = 7                 // palette slot 0–6, 7 = multicolour
    /// Side lights [effect, colour, brightness, speed]; nil leaves them as they are.
    public var side: [Int]?

    // App looks (live stream)
    /// "dark", "solid", "wave" or "effect:<n>" (n from `Backgrounds.available`).
    public var background = "dark"
    public var color = RGB(r: 160, g: 0, b: 255)
    public var backgroundSpeed = 2
    public var multicolour = true
    public var liveBrightness = 1.0
    public var keyColors: [String: RGB] = [:]

    public init(id: String = UUID().uuidString, name: String, kind: Kind) {
        self.id = id; self.name = name; self.kind = kind
    }

    public static func keyboard(_ id: String, _ name: String, effect: Int, brightness: Int = 4, speed: Int = 2, colour: Int = 7, side: [Int]? = nil, favourite: Bool = false) -> Look {
        var l = Look(id: id, name: name, kind: .keyboard)
        l.effect = effect; l.brightness = brightness; l.speed = speed; l.colour = colour; l.side = side; l.favourite = favourite; l.builtIn = true
        return l
    }

    public static func app(_ id: String, _ name: String, background: String, keyColors: [String: RGB], color: RGB = RGB(r: 160, g: 0, b: 255), multicolour: Bool = true, brightness: Double = 1, favourite: Bool = false) -> Look {
        var l = Look(id: id, name: name, kind: .app)
        l.background = background; l.keyColors = keyColors; l.color = color; l.multicolour = multicolour; l.liveBrightness = brightness; l.favourite = favourite; l.builtIn = true
        return l
    }

    public var needsApp: Bool { kind == .app }
    /// Effects that react to typing can't be drawn by the app, so they only exist as keyboard looks.
    public static let reactiveEffects: Set<Int> = [4, 7, 9, 12]
    public var reactsToTyping: Bool { kind == .keyboard && Self.reactiveEffects.contains(effect) }

    /// Background effect number for app looks, if the background is an effect.
    public var backgroundEffect: Int? {
        background.hasPrefix("effect:") ? Int(background.dropFirst(7)) : nil
    }
    public var backgroundName: String {
        switch background {
        case "dark": return "Dark"
        case "solid": return "Solid colour"
        case "wave": return "Rainbow wave"
        default: return backgroundEffect.map(Backgrounds.name) ?? background
        }
    }

    // MARK: Keyboard looks ↔ lighting block

    /// The lighting block with this look written into it. Other effects' settings are kept.
    public func applied(to block: LightingBlock) throws -> LightingBlock {
        guard kind == .keyboard else { throw F65Error.invalid("App looks aren't saved on the keyboard.") }
        var b = block
        try b.setEffect(effect)
        try b.setSlot(effect, brightness: brightness, speed: speed, colour: colour)
        if let side, side.count == 4 {
            for (field, v) in zip(["sideEffect", "sideColour", "sideBrightness", "sideSpeed"], side) {
                try b.set(field, value: min(max(v, 0), LightingBlock.sideRange(field).upperBound))
            }
        }
        return b
    }

    /// A keyboard look describing what the block shows now.
    public static func capture(_ block: LightingBlock, name: String? = nil) -> Look {
        let e = (1...18).contains(block.effect) ? block.effect : 1
        var l = Look(name: name ?? LightingBlock.names[e - 1], kind: .keyboard)
        l.effect = e; l.brightness = block.brightness(e); l.speed = block.speed(e); l.colour = block.colour(e)
        l.side = [block.side("sideEffect"), block.side("sideColour"), block.side("sideBrightness"), block.side("sideSpeed")]
        return l
    }

    /// True when the keyboard is showing this look (side lights are compared only when the look sets them).
    public func matches(_ block: LightingBlock) -> Bool {
        guard kind == .keyboard, block.effect == effect, block.brightness(effect) == brightness,
              block.speed(effect) == speed, block.colour(effect) == colour else { return false }
        guard let side, side.count == 4 else { return true }
        return side == [block.side("sideEffect"), block.side("sideColour"), block.side("sideBrightness"), block.side("sideSpeed")]
    }

    // MARK: App looks ↔ live settings

    /// Live settings for this look. Keyboard looks turn the stream off so the saved lighting shows.
    public func liveSettings(_ base: Settings) -> Settings {
        var s = base
        s.paused = false
        guard kind == .app else { s.mode = .off; s.keyColors = [:]; return s }
        switch background {
        case "solid": s.mode = .solid
        case "wave": s.mode = .wave
        case "dark": s.mode = .dark
        default:
            if let e = backgroundEffect, Backgrounds.available.contains(e) { s.mode = .effect; s.effect = e } else { s.mode = .dark }
        }
        s.color = color
        s.effectSpeed = min(max(backgroundSpeed, 0), 4)
        s.effectMulticolour = multicolour
        s.brightness = min(max(liveBrightness, 0), 1)
        s.keyColors = keyColors.filter { PhysicalKey.slots[$0.key] != nil }
        return s
    }

    /// An app look from live settings (for "Save as look" and the command bar).
    public static func fromLive(_ s: Settings, name: String) -> Look {
        var l = Look(name: name, kind: .app)
        switch s.mode {
        case .solid: l.background = "solid"
        case .wave: l.background = "wave"
        case .effect: l.background = "effect:\(s.effect)"
        default: l.background = "dark"
        }
        l.color = s.color; l.backgroundSpeed = s.effectSpeed; l.multicolour = s.effectMulticolour
        l.liveBrightness = s.brightness; l.keyColors = s.keyColors
        return l
    }

    // MARK: Preview

    /// Preview levels for onboard brightness 0–4 (same as the keyboard preview).
    public static let brightnessLevels = [0, 0.3, 0.55, 0.8, 1.0]

    /// One preview frame (126 LED slots) at `time`. Keyboard looks are approximations of the onboard effect.
    public func previewFrame(time: Double, palette: [RGB]) -> [RGB] {
        switch kind {
        case .keyboard:
            let c = colour < 7 && colour < palette.count ? palette[colour] : RGB(r: 255, g: 255, b: 255)
            var f = Backgrounds.frame(effect: effect, time: time, speed: speed, multicolour: colour == 7, color: c)
            if Self.reactiveEffects.contains(effect) { f = f.map { $0.scaled(0.25) } }   // dark until you type
            let level = Self.brightnessLevels[min(max(brightness, 0), 4)]
            return f.map { $0.scaled(level) }
        case .app:
            return FrameRenderer.render(liveSettings(Settings()), map: KeyMap.fallback, time: time, receiver: false)
        }
    }
}

// Codable with defaults so older or hand-edited files still load.
extension Look {
    enum CodingKeys: String, CodingKey { case id, name, kind, favourite, builtIn, effect, brightness, speed, colour, side, background, color, backgroundSpeed, multicolour, liveBrightness, keyColors }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Look"
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .keyboard
        favourite = try c.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
        effect = min(max(try c.decodeIfPresent(Int.self, forKey: .effect) ?? 1, 1), 18)
        brightness = min(max(try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 4, 0), 4)
        speed = min(max(try c.decodeIfPresent(Int.self, forKey: .speed) ?? 2, 0), 4)
        colour = min(max(try c.decodeIfPresent(Int.self, forKey: .colour) ?? 7, 0), 7)
        side = try c.decodeIfPresent([Int].self, forKey: .side).flatMap { $0.count == 4 ? $0 : nil }
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "dark"
        color = (try c.decodeIfPresent(String.self, forKey: .color)).flatMap(RGB.init(string:)) ?? RGB(r: 160, g: 0, b: 255)
        backgroundSpeed = min(max(try c.decodeIfPresent(Int.self, forKey: .backgroundSpeed) ?? 2, 0), 4)
        multicolour = try c.decodeIfPresent(Bool.self, forKey: .multicolour) ?? true
        liveBrightness = min(max(try c.decodeIfPresent(Double.self, forKey: .liveBrightness) ?? 1, 0), 1)
        let raw = try c.decodeIfPresent([String: String].self, forKey: .keyColors) ?? [:]
        keyColors = raw.reduce(into: [:]) { out, kv in if PhysicalKey.slots[kv.key] != nil, let rgb = RGB(string: kv.value) { out[kv.key] = rgb } }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind)
        try c.encode(favourite, forKey: .favourite); try c.encode(builtIn, forKey: .builtIn)
        if kind == .keyboard {
            try c.encode(effect, forKey: .effect); try c.encode(brightness, forKey: .brightness); try c.encode(speed, forKey: .speed); try c.encode(colour, forKey: .colour)
            try c.encodeIfPresent(side, forKey: .side)
        } else {
            try c.encode(background, forKey: .background); try c.encode(color.hex, forKey: .color); try c.encode(backgroundSpeed, forKey: .backgroundSpeed)
            try c.encode(multicolour, forKey: .multicolour); try c.encode(liveBrightness, forKey: .liveBrightness)
            try c.encode(keyColors.mapValues { $0.hex }, forKey: .keyColors)
        }
    }
}

// MARK: - Store

/// Looks saved as JSON in the support folder. Starts with the starter looks.
public final class LookStore {
    public private(set) var looks: [Look]
    public let url: URL

    public init(url: URL = AppPaths.supportDir.appendingPathComponent("looks.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Look].self, from: data), !saved.isEmpty {
            looks = saved
        } else {
            looks = Self.starters
        }
    }

    public static let starters: [Look] = {
        let red = RGB(r: 255, g: 30, b: 30), amber = RGB(r: 255, g: 170, b: 50), dimAmber = RGB(r: 110, g: 70, b: 20), cyan = RGB(r: 0, g: 220, b: 255)
        func keys(_ ids: [String], _ c: RGB) -> [String: RGB] { Dictionary(uniqueKeysWithValues: ids.map { ($0, c) }) }
        let sunset = Dictionary(uniqueKeysWithValues: KeyGeometry.keys.map { k -> (String, RGB) in
            let t = k.cx / 16
            return (k.id, RGB(r: 255, g: UInt8(max(0, 150 - 130 * t)), b: UInt8(min(255, 30 + 200 * t))))
        })
        return [
            .keyboard("waterfall", "Waterfall", effect: 16, brightness: 4, speed: 2, colour: 7, favourite: true),
            .keyboard("wheel", "Rainbow wheel", effect: 6, brightness: 3, speed: 2, colour: 7, favourite: true),
            .keyboard("breathing", "Calm breathing", effect: 2, brightness: 3, speed: 1, colour: 5),
            .keyboard("desk", "Desk light", effect: 1, brightness: 2, speed: 2, colour: 6, favourite: true),
            .keyboard("stars", "Starfield", effect: 8, brightness: 4, speed: 1, colour: 7),
            .keyboard("storm", "Storm", effect: 18, brightness: 4, speed: 2, colour: 2),
            .keyboard("ripples", "Ripples", effect: 7, brightness: 4, speed: 2, colour: 7),
            .app("wasd", "WASD focus", background: "wave", keyColors: keys(["w", "a", "s", "d"], red), favourite: true),
            .app("night", "Night coder", background: "dark", keyColors: keys(["f", "j"], amber).merging(keys(["up", "down", "left", "right"], dimAmber)) { a, _ in a }, brightness: 0.8),
            .app("sunset", "Sunset", background: "dark", keyColors: sunset),
            .app("synth", "Synthwave", background: "effect:13", keyColors: keys(["space", "enter", "esc"], cyan), color: RGB(r: 255, g: 0, b: 200), multicolour: false),
        ]
    }()

    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(looks).write(to: url, options: .atomic)
    }

    public func look(_ id: String?) -> Look? { looks.first { $0.id == id } }
    public var favourites: [Look] { looks.filter(\.favourite) }

    /// Adds a look, making its name unique. Returns the stored look.
    @discardableResult public func add(_ look: Look) -> Look {
        var l = look
        if looks.contains(where: { $0.id == l.id }) { l.id = UUID().uuidString }
        l.builtIn = false
        l.name = uniqueName(l.name)
        looks.append(l); try? save()
        return l
    }
    public func update(_ look: Look) {
        guard let i = looks.firstIndex(where: { $0.id == look.id }) else { return }
        looks[i] = look; try? save()
    }
    public func remove(_ id: String) { looks.removeAll { $0.id == id }; try? save() }
    public func toggleFavourite(_ id: String) {
        guard let i = looks.firstIndex(where: { $0.id == id }) else { return }
        looks[i].favourite.toggle(); try? save()
    }
    /// The favourite after `id` (wrapping), or the first favourite.
    public func nextFavourite(after id: String?) -> Look? {
        let f = favourites
        guard !f.isEmpty else { return nil }
        guard let id, let i = f.firstIndex(where: { $0.id == id }) else { return f[0] }
        return f[(i + 1) % f.count]
    }
    /// The first keyboard look the block is showing.
    public func matching(_ block: LightingBlock) -> Look? { looks.first { $0.matches(block) } }

    func uniqueName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces).isEmpty ? "My look" : base.trimmingCharacters(in: .whitespaces)
        var name = trimmed, n = 2
        while looks.contains(where: { $0.name == name }) { name = "\(trimmed) \(n)"; n += 1 }
        return name
    }
}

// MARK: - Key regions

public enum KeyRegions {
    public static let all: [(name: String, ids: [String])] = [
        ("All", PhysicalKey.ids),
        ("Letters", "qwertyuiopasdfghjklzxcvbnm".map(String.init)),
        ("Numbers", ["d1", "d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9", "d0"]),
        ("Modifiers", ["tab", "caps", "lshift", "rshift", "lctrl", "lwin", "lalt", "fn", "rctrl"]),
        ("Arrows", ["up", "down", "left", "right"]),
        ("WASD", ["w", "a", "s", "d"]),
        ("Home row", ["a", "s", "d", "f", "j", "k", "l", "semi"]),
        ("Space bar", ["space"]),
    ]
    public static func ids(_ name: String) -> [String]? { all.first { $0.name.lowercased() == name.lowercased() }?.ids }
}

// MARK: - Colour slots

public extension Palette {
    /// Index of the palette colour closest to `c`.
    static func nearestSlot(to c: RGB, in colours: [RGB]) -> Int {
        colours.indices.min { colours[$0].distance(to: c) < colours[$1].distance(to: c) } ?? 0
    }
}
public extension LightingBlock {
    /// Effects (1–18) whose saved colour is palette slot `slot`.
    func effects(usingColour slot: Int) -> [Int] { (1...18).filter { colour($0) == slot } }
    /// The palette slot used by the fewest effects, never `keeping`. Ties go to the higher slot.
    func leastUsedColourSlot(keeping: Int?) -> Int {
        (0..<7).filter { $0 != keeping }.min { a, b in
            let ua = effects(usingColour: a).count, ub = effects(usingColour: b).count
            return ua == ub ? a > b : ua < ub
        } ?? 6
    }
}

// MARK: - 2.4G frame budget

public enum LiveBudget {
    /// Bytes the per-key colours take in one 2.4G frame (4 bytes per colour group + 1 per key).
    public static func pinnedBytes(_ keyColors: [String: RGB]) -> Int {
        var groups: [RGB: Int] = [:]
        for (id, c) in keyColors where PhysicalKey.slots[id] != nil && !c.isBlack { groups[c, default: 0] += 1 }
        return groups.values.reduce(0) { $0 + 4 + $1 }
    }
    public static var frameBytes: Int { ReceiverProtocol.maxBytes }
}

// MARK: - Restore point dates

public extension BackupStore {
    /// Time a restore point was written: from the app's file name (f65-yyyyMMdd-HHmmss-SSS-…), else the file date.
    static func date(of url: URL) -> Date? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        if parts.count >= 4, parts[0] == "f65" {
            let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmssSSS"; f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: "\(parts[1])\(parts[2])\(parts[3])") { return d }
        }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
    /// The lighting block saved in a restore point, if it has one.
    func lighting(in url: URL) -> LightingBlock? {
        guard let r = try? load(url).first(where: { $0.cmd == 0x44 && $0.sub == 0 }) else { return nil }
        return try? LightingBlock(r.bytes)
    }
}
