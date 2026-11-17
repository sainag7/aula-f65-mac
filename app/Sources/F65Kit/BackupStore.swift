import Foundation
public struct BackupRecord: Equatable {
    public let cmd: UInt8; public let sub: UInt8; public var bytes: [UInt8]
    public init(cmd: UInt8, sub: UInt8, bytes: [UInt8]) { self.cmd=cmd; self.sub=sub; self.bytes=bytes }
}
public final class BackupStore {
    public let directory: URL
    public init(directory: URL = AppPaths.supportDir.appendingPathComponent("backups")) { self.directory=directory }
    public static func parse(_ text: String) throws -> [BackupRecord] {
        var out: [BackupRecord]=[]
        for line in text.split(whereSeparator: \.isNewline) {
            let p=line.split(whereSeparator: \.isWhitespace)
            guard p.count>2, let cmd=UInt8(p[0],radix:16), [UInt8(0x41),0x44,0x49].contains(cmd), let sub=UInt8(p[1]) else { throw F65Error.invalid("Invalid restore point header.") }
            let bytes=p.dropFirst(2).compactMap { $0.count==2 ? UInt8($0,radix:16) : nil }
            guard bytes.count==p.count-2, !out.contains(where: {$0.cmd==cmd && $0.sub==sub}) else { throw F65Error.invalid("Invalid bytes or duplicate block in restore point.") }
            try Blocks.validate(cmd&15,sub:sub,bytes);out.append(.init(cmd:cmd,sub:sub,bytes:bytes))
        }
        guard !out.isEmpty else { throw F65Error.invalid("Empty restore point.") };return out
    }
    public func load(_ url: URL) throws -> [BackupRecord] { try Self.parse(String(contentsOf:url,encoding:.utf8)) }
    public func write(_ snapshot: Snapshot) throws -> URL {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let f=DateFormatter();f.dateFormat="yyyyMMdd-HHmmss-SSS"
        let url=directory.appendingPathComponent("f65-\(f.string(from:Date()))-\(UUID().uuidString.prefix(8)).txt")
        let s=snapshot.records.map { String(format:"%02x %d ",$0.cmd,$0.sub)+hex($0.bytes) }.joined(separator:"\n")
        try s.write(to:url,atomically:true,encoding:.utf8);return url
    }
    public func list() -> [URL] { ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).filter {$0.pathExtension=="txt"}.sorted {$0.lastPathComponent>$1.lastPathComponent} }
}
// Port of f65.swift save(): two attempts, then two verified rollback attempts.
// Backup contents are checked against the fresh previous block before any write is allowed.
@discardableResult public func safeSave(_ t: Transport, cmd: UInt8, sub: UInt8 = 0, new: [UInt8], old: [UInt8], backup: URL, progress: WriteProgress = {_,_,_ in}) throws -> [UInt8] {
    try Blocks.validate(cmd,sub:sub,new);try Blocks.validate(cmd,sub:sub,old)
    let records=try BackupStore().load(backup)
    guard records.contains(where: {$0.cmd==cmd|0x40 && $0.sub==sub && $0.bytes==old}) else { throw F65Error.invalid("Backup does not contain the previous block. Nothing was saved.") }
    if t.kind == .receiver { if try t.read(7,sub:0).first != 1 { throw F65Error.asleep } }
    let changed=new.indices.filter {new[$0] != old[$0]}
    if changed.isEmpty { return old }
    func attempt(_ data:[UInt8], rollback:Bool) -> [UInt8]? {
        do {
            try t.write(cmd,sub:sub,data:data,progress:progress)
            let back=try t.read(cmd|0x40,sub:sub)
            guard back.count==data.count else { return nil }
            // A partial radio write may alter any byte. Rollback validates all stable bytes,
            // not just the original edit; LED 0x0e is documented as volatile.
            let check=rollback ? data.indices.filter { !(cmd==4 && $0==0x0e) } : changed
            return check.allSatisfy {back[$0]==data[$0]} ? back : nil
        } catch { return nil }
    }
    for _ in 0..<2 { if let back=attempt(new,rollback:false) { return back } }
    for _ in 0..<2 { if attempt(old,rollback:true) != nil { throw F65Error.verifyFailed(rolledBack:true,backup:backup) } }
    throw F65Error.verifyFailed(rolledBack:false,backup:backup)
}
