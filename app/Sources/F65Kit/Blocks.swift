// Settings formats ported from f65.swift. The recovery CLIs remain independent.
import Foundation

public enum F65Error: Error, LocalizedError {
    case notFound, notPermitted, asleep, timeout(UInt8), nak(UInt8), incomplete(UInt8), invalid(String)
    case verifyFailed(rolledBack: Bool, backup: URL)
    public var errorDescription: String? {
        switch self {
        case .notFound: return "AULA F65 not connected."
        case .notPermitted: return "Needs Input Monitoring permission."
        case .asleep: return "Press any key on the F65 to wake it. Nothing was saved."
        case .timeout(let c): return String(format: "Keyboard did not answer command %02x. Retry when awake.", c)
        case .nak(let c): return String(format: "Keyboard rejected command %02x.", c)
        case .incomplete(let c): return String(format: "Incomplete reply for %02x. Nothing was saved.", c)
        case .invalid(let s): return s
        case .verifyFailed(let ok, let url): return ok ? "Rolled back: the keyboard is as it was before. Nothing was changed." : "ROLLBACK FAILED. Restore \(url.path), ideally over the USB cable."
        }
    }
}
public enum Blocks {
    public static let cableMap: [UInt8: (cmd: UInt8, len: Int)] = [1:(3,504),0x41:(3,504),4:(4,128),0x44:(4,128),9:(10,490),0x49:(10,490),0x43:(5,512)]
    public static func validate(_ cmd: UInt8, sub: UInt8, _ bytes: [UInt8]) throws {
        guard [UInt8(1),4,9].contains(cmd), sub == 0 || (cmd == 1 && sub == 1), bytes.count == cableMap[cmd]?.len else { throw F65Error.invalid("Blocked command, layer or block size.") }
        if cmd == 4 { _ = try LightingBlock(bytes) }
    }
}
public struct LightingBlock: Equatable {
    public private(set) var bytes: [UInt8]
    public init(_ bytes: [UInt8]) throws {
        guard bytes.count == 128, bytes.suffix(2) == [0x5a,0xa5] else { throw F65Error.invalid("Lighting block must be 128 bytes with 5a a5 marker.") }
        self.bytes = bytes
    }
    public var effect: Int { Int(bytes[10]) }
    public func brightness(_ e: Int) -> Int { (1...18).contains(e) ? Int(bytes[0x38+2*e]) : 0 }
    public func speed(_ e: Int) -> Int { (1...18).contains(e) ? Int(bytes[0x39+2*e] >> 4) : 0 }
    public func colour(_ e: Int) -> Int { (1...18).contains(e) ? Int(bytes[0x39+2*e] & 15) : 7 }
    public mutating func setEffect(_ e: Int) throws { guard (1...18).contains(e) else { throw F65Error.invalid("Effect must be 1–18.") }; bytes[10] = UInt8(e) }
    public mutating func set(_ field: String, value: Int) throws {
        guard (1...18).contains(effect), (0...(field == "colour" ? 7 : 4)).contains(value) else { throw F65Error.invalid("Unsupported effect or value.") }
        let s = 0x38 + 2*effect
        switch field {
        case "brightness": bytes[s] = UInt8(value)
        case "speed": bytes[s+1] = UInt8(value << 4) | (bytes[s+1] & 15)
        case "colour": bytes[s+1] = (bytes[s+1] & 0xf0) | UInt8(value)
        default: throw F65Error.invalid("Unknown lighting setting.")
        }
    }
    public static let names = ["Fixed", "Breathing", "Rainbow", "Flash away", "Raindrops", "Rainbow wheel", "Ripples", "Stars", "Shadow", "Snake", "Neon", "Reaction", "Sine wave", "Scanning", "Windmill", "Waterfall", "Blossom", "Storm"]
    public var name: String { (1...18).contains(effect) ? Self.names[effect-1] : "Unsupported effect \(effect)" }
}
public struct Palette: Equatable {
    public private(set) var bytes: [UInt8]
    public init(_ b: [UInt8]) throws { guard b.count == 490 else { throw F65Error.invalid("Palette must be 490 bytes.") }; bytes = b }
    public var colours: [RGB] { (0..<7).map { RGB(r: bytes[$0*3], g: bytes[$0*3+1], b: bytes[$0*3+2]) } }
    public mutating func set(_ i: Int, _ c: RGB) throws {
        guard (0..<7).contains(i) else { throw F65Error.invalid("Invalid palette index.") }
        for g in 0..<23 { bytes.replaceSubrange((g*21+i*3)..<(g*21+i*3+3), with: [c.r,c.g,c.b]) }
    }
    public mutating func reset() { for (i,c) in Self.factory.enumerated() { try! set(i,c) } }
    public static let factory = [RGB(r:255,g:0,b:0),RGB(r:0,g:255,b:0),RGB(r:0,g:0,b:255),RGB(r:255,g:255,b:0),RGB(r:255,g:0,b:255),RGB(r:0,g:255,b:255),RGB(r:255,g:255,b:255)]
}
public struct KeyEntry: Equatable {
    public let bytes: [UInt8]
    public init(_ b: [UInt8]) { precondition(b.count == 4); bytes = b }
    public var protected: Bool { bytes[0] == 8 || bytes[0] == 13 }
    public var empty: Bool { bytes == [0,0,0,0] }
    public var description: String { empty ? "Disabled / empty" : bytes[0] == 13 ? "Fn (protected)" : describeKey(bytes).components(separatedBy: "  ").dropFirst().joined(separator: " ") }
    public var hex: String { F65Kit.hex(bytes) }
    public static func named(_ name: String) -> KeyEntry? { keyEntry(name).map(KeyEntry.init) }
}
public struct KeyLayer: Equatable {
    public private(set) var bytes: [UInt8]
    public init(_ b: [UInt8]) throws { guard b.count == 504 else { throw F65Error.invalid("Key layer must be 504 bytes.") }; bytes = b }
    public func entry(_ slot: Int) -> KeyEntry { KeyEntry(Array(bytes[slot*4..<slot*4+4])) }
    public mutating func set(_ slot: Int, _ e: KeyEntry, allowProtected: Bool = false) throws {
        guard PhysicalKey.slots.values.contains(slot), allowProtected || !entry(slot).protected else { throw F65Error.invalid("Fn and connection bindings are protected. Confirm the warning first.") }
        bytes.replaceSubrange(slot*4..<slot*4+4, with: e.bytes)
    }
}
public struct Snapshot: Equatable {
    public var lighting: LightingBlock; public var palette: Palette; public var base: KeyLayer; public var fn: KeyLayer
    public init(_ t: Transport) throws {
        lighting = try LightingBlock(t.read(0x44, sub: 0)); palette = try Palette(t.read(0x49, sub: 0))
        base = try KeyLayer(t.read(0x41, sub: 0)); fn = try KeyLayer(t.read(0x41, sub: 1))
    }
    public var records: [BackupRecord] { [.init(cmd:0x44,sub:0,bytes:lighting.bytes),.init(cmd:0x41,sub:0,bytes:base.bytes),.init(cmd:0x41,sub:1,bytes:fn.bytes),.init(cmd:0x49,sub:0,bytes:palette.bytes)] }
}
public enum PhysicalKey {
    public static let rows = ["esc d1 d2 d3 d4 d5 d6 d7 d8 d9 d0 minus equal bksp del", "tab q w e r t y u i o p lbr rbr bslash pgup", "caps a s d f g h j k l semi quote enter pgdn", "lshift z x c v b n m comma period slash rshift up end", "lctrl lwin lalt space fn rctrl left down right"].map { $0.split(separator:" ").map(String.init) }
    public static let indices = [[1,7,13,19,25,31,37,43,49,55,61,67,73,79,91],[2,8,14,20,26,32,38,44,50,56,62,68,74,80,92],[3,9,15,21,27,33,39,45,51,57,63,69,81,93],[4,10,16,22,28,34,40,46,52,58,64,82,88,94],[5,11,17,35,59,65,83,89,95]]
    public static let ids = rows.flatMap { $0 }
    public static let slots = Dictionary(uniqueKeysWithValues: zip(ids, indices.flatMap { $0 }))
}
public func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format:"%02x",$0) }.joined(separator:" ") }
