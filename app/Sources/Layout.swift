// Custom layout file: ~/Library/Application Support/F65Lighting/layout.json
//   {"rest": "#100020", "keys": {"w": "#ff0000", "esc": "#00ffff"}}

import Foundation

struct LayoutSpec: Equatable {
    var rest: RGB = RGB(r: 0x10, g: 0x00, b: 0x20)
    var keys: [String: RGB] = [:]
    var problems: [String] = []   // parse problems (bad colours, bad JSON)

    static let template = """
    {
      "rest": "#100020",
      "keys": {
        "esc": "#00ffff",
        "w": "#ff0000",
        "a": "#ff0000",
        "s": "#ff0000",
        "d": "#ff0000",
        "space": "#ffffff"
      }
    }

    """

    /// Creates the file from the template if it doesn't exist yet.
    @discardableResult
    static func ensureFile() -> URL {
        let url = AppPaths.layoutURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    static func load() -> LayoutSpec {
        let url = ensureFile()
        var spec = LayoutSpec()
        guard let data = try? Data(contentsOf: url) else {
            spec.problems.append("Could not read \(url.path)")
            return spec
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            spec.problems.append("layout.json is not valid JSON")
            return spec
        }
        if let r = obj["rest"] {
            if let s = r as? String, let c = RGB(string: s) { spec.rest = c } else { spec.problems.append("bad \"rest\" colour") }
        }
        if let keys = obj["keys"] as? [String: Any] {
            for (k, v) in keys {
                if let s = v as? String, let c = RGB(string: s) { spec.keys[k.lowercased()] = c }
                else { spec.problems.append("bad colour for \"\(k)\"") }
            }
        } else if obj["keys"] != nil {
            spec.problems.append("\"keys\" must be an object")
        }
        return spec
    }

    /// Full 126-slot frame for this layout. Returns key names that aren't on the keyboard.
    func resolve(_ map: KeyMap) -> (frame: [RGB], unknown: [String]) {
        var frame = [RGB](repeating: rest, count: KeyMap.slotCount)
        frame[0] = .black
        var unknown: [String] = []
        for (name, c) in keys.sorted(by: { $0.key < $1.key }) {
            guard let slots = map.slots(for: name) else { unknown.append(name); continue }
            for s in slots { frame[s] = c }
        }
        return (frame, unknown)
    }
}
