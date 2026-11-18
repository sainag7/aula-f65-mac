// ⌘K command bar: short phrases turned into concrete actions ("wasd red", "dim 50", "storm", "undo").
// Pure and testable; the app runs the chosen command.

import Foundation

public enum LookCommand: Equatable {
    case paint([String], RGB)      // PhysicalKey ids, colour (app look over what's showing)
    case brightness(Int)           // percent 0–100
    case lightsOff
    case undo
    case apply(String)             // look id
    case effect(Int)               // onboard effect 1–18 (keyboard look)
    case colour(RGB)               // colour for the current look
}

public struct CommandSuggestion: Equatable {
    public let title: String
    public let detail: String
    public let symbol: String      // SF Symbol name
    public let command: LookCommand
}

public enum CommandParser {
    static let colourNames: [String: RGB] = [
        "red": RGB(r: 255, g: 0, b: 0), "green": RGB(r: 0, g: 255, b: 0), "blue": RGB(r: 0, g: 0, b: 255),
        "yellow": RGB(r: 255, g: 255, b: 0), "magenta": RGB(r: 255, g: 0, b: 255), "pink": RGB(r: 255, g: 0, b: 120),
        "cyan": RGB(r: 0, g: 255, b: 255), "white": RGB(r: 255, g: 255, b: 255), "orange": RGB(r: 255, g: 100, b: 0),
        "purple": RGB(r: 160, g: 0, b: 255), "amber": RGB(r: 255, g: 170, b: 50),
    ]
    static let regionNames: [String: String] = [
        "wasd": "WASD", "arrows": "Arrows", "arrow": "Arrows", "letters": "Letters", "numbers": "Numbers", "digits": "Numbers",
        "modifiers": "Modifiers", "mods": "Modifiers", "space": "Space bar", "spacebar": "Space bar", "all": "All", "everything": "All", "home": "Home row",
    ]
    static let keyAliases: [String: String] = [
        "esc": "esc", "escape": "esc", "enter": "enter", "return": "enter", "tab": "tab", "caps": "caps", "backspace": "bksp",
        "delete": "del", "del": "del", "fn": "fn", "shift": "lshift", "ctrl": "lctrl", "control": "lctrl", "alt": "lalt", "option": "lalt",
    ]

    /// Up to six suggestions for `text`, best first. `keyboardLook` says whether the current look is saved on the keyboard.
    public static func suggestions(_ text: String, looks: [Look], keyboardLook: Bool, palette: [RGB]) -> [CommandSuggestion] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let words = q.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        var out: [CommandSuggestion] = []

        let colour = words.lazy.compactMap { w -> RGB? in colourNames[w] ?? (w.hasPrefix("#") ? RGB(string: w) : nil) }.first
        var keys: [String] = []
        var region: String?
        for (i, w) in words.enumerated() {
            if w == "home", words.indices.contains(i + 1), words[i + 1] == "row" { region = "Home row"; continue }
            if let r = regionNames[w] { region = r }
            else if let k = keyAliases[w] { keys.append(k) }
            else if w.count == 1, PhysicalKey.slots[w] != nil { keys.append(w) }
            else if w.count == 1, let d = Int(w) { keys.append("d\(d)") }
        }
        if let region, let ids = KeyRegions.ids(region) { keys = ids + keys.filter { !ids.contains($0) } }
        let number = words.lazy.compactMap { Int($0.replacingOccurrences(of: "%", with: "")) }.first { (0...100).contains($0) }

        if let colour, !keys.isEmpty {
            let what = region ?? keys.map(keyLabel).joined(separator: " ")
            out.append(.init(title: "Paint \(what) \(name(of: colour))", detail: "Needs app · over what's showing now", symbol: "paintbrush", command: .paint(keys, colour)))
        }
        if let first = words.first, ["dim", "brightness", "bright"].contains(first) {
            let pct = number ?? (first == "bright" ? 100 : 50)
            let step = Int((Double(pct) / 25).rounded())
            out.append(.init(title: "Brightness \(pct)%", detail: keyboardLook ? "keyboard step \(step) of 4" : "live brightness", symbol: "sun.max", command: .brightness(pct)))
        } else if number != nil, words.count == 1, q.hasSuffix("%") {
            out.append(.init(title: "Brightness \(number!)%", detail: keyboardLook ? "keyboard step \(Int((Double(number!) / 25).rounded())) of 4" : "live brightness", symbol: "sun.max", command: .brightness(number!)))
        }
        if words == ["off"] || q == "lights off" {
            out.append(.init(title: "Lights off", detail: keyboardLook ? "brightness 0 · saved on keyboard" : "live brightness 0", symbol: "moon", command: .lightsOff))
        }
        if words.first == "undo" { out.append(.init(title: "Undo last change", detail: "⌘Z", symbol: "arrow.uturn.backward", command: .undo)) }
        if let colour, keys.isEmpty {
            let i = palette.firstIndex(of: colour)
            out.append(.init(title: "Colour: \(name(of: colour))", detail: keyboardLook ? (i.map { "keyboard colour \($0 + 1)" } ?? "not one of the keyboard's 7: you'll pick a slot") : "app look colour", symbol: "paintpalette", command: .colour(colour)))
        }
        for l in looks where l.name.lowercased().contains(q) || q.contains(l.name.lowercased()) {
            out.append(.init(title: "Apply \(l.name)", detail: l.kind == .keyboard ? "On keyboard" : "Needs app", symbol: "square.grid.2x2", command: .apply(l.id)))
        }
        if q.count >= 3 {
            for (i, n) in LightingBlock.names.enumerated() where n.lowercased().contains(q) && !looks.contains(where: { $0.name == n }) {
                out.append(.init(title: "Switch to \(n)", detail: "effect \(i + 1) · saved on keyboard", symbol: "keyboard", command: .effect(i + 1)))
            }
        }
        return Array(out.prefix(6))
    }

    static func name(of c: RGB) -> String { colourNames.first { $0.value == c }?.key ?? c.hex }
    static func keyLabel(_ id: String) -> String {
        if id.hasPrefix("d"), id.count == 2 { return String(id.dropFirst()) }
        return id.count == 1 ? id.uppercased() : id.capitalized
    }
}
