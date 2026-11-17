import Foundation

public enum LinkKind: String { case cable, receiver
    public var title: String { self == .cable ? "Cable" : "2.4G" }
}
public typealias WriteProgress = (Int, Int, Bool) -> Void
public protocol Transport: AnyObject {
    var kind: LinkKind { get }
    func read(_ cmd: UInt8, sub: UInt8) throws -> [UInt8]
    func write(_ cmd: UInt8, sub: UInt8, data: [UInt8], progress: WriteProgress) throws
    func sendLive(_ colors: [RGB], slots: [Int]) -> Bool
    func drain()
}
public extension Transport { func drain() {} }
public protocol PacketChannel: AnyObject {
    func send(_ packet: [UInt8]) throws
    func receive(timeout: TimeInterval) -> [UInt8]?
    func drain()
}
public enum SettingsPacket {
    public static func receiver(_ cmd: UInt8, sub: UInt8, count: Int = 1, index: Int = 0, data: [UInt8] = []) -> [UInt8] {
        precondition(data.count <= 14 && count > 0 && count < 128 && index < count && sub < 16)
        var p = [UInt8](repeating:0,count:20)
        p[0]=0x13; p[1]=cmd; p[2]=UInt8(count); p[3]=UInt8(index); p[4]=(sub << 4)|UInt8(data.count)
        p.replaceSubrange(5..<5+data.count,with:data); p[19]=ReceiverProtocol.checksum(p); return p
    }
    public static func cable(_ cmd: UInt8, sub: UInt8, length: Int) -> [UInt8] {
        var p = [UInt8](repeating:0,count:520)
        p[0]=6;p[1]=cmd;p[2]=sub;p[4]=1;p[6]=UInt8(length&255);p[7]=UInt8(length>>8);return p
    }
}
// The same packet engine is used by the HID and fault-injection channels.
public final class ReceiverTransport: Transport {
    public let kind = LinkKind.receiver
    let channel: PacketChannel
    public var timeout: TimeInterval = 0.35
    public var tries = 8
    public init(_ channel: PacketChannel) { self.channel = channel }
    public func drain() { channel.drain() }
    public func read(_ cmd: UInt8, sub: UInt8 = 0) throws -> [UInt8] {
        guard [UInt8(7),0x41,0x43,0x44,0x49,0x4a].contains(cmd), sub == 0 || (cmd == 0x41 && sub == 1) else { throw F65Error.invalid("Read command blocked.") }
        let length = cmd == 7 ? 1 : cmd == 0x4a ? 2 : Blocks.cableMap[cmd]!.len
        let count = (length+13)/14
        var chunks: [Int:[UInt8]] = [:]
        for _ in 0..<tries {
            channel.drain(); try channel.send(SettingsPacket.receiver(cmd,sub:sub))
            let deadline = Date().addingTimeInterval(timeout * 3)
            while Date() < deadline, let p = channel.receive(timeout:min(timeout,deadline.timeIntervalSinceNow)) {
                guard valid(p), p[1]&0x7f == cmd else { continue }
                if p[1]&0x80 != 0 { throw F65Error.nak(cmd) }
                let idx=Int(p[3]), n=Int(p[4]&15)
                guard p[4]>>4 == sub, Int(p[2]&127)==count, idx<count, n==min(14,length-idx*14) else { continue }
                chunks[idx]=Array(p[5..<5+n])
                if chunks.count == count { return (0..<count).flatMap { chunks[$0]! } }
            }
        }
        throw chunks.isEmpty ? F65Error.timeout(cmd) : F65Error.incomplete(cmd)
    }
    public func write(_ cmd: UInt8, sub: UInt8 = 0, data: [UInt8], progress: WriteProgress) throws {
        try Blocks.validate(cmd,sub:sub,data)
        let count=(data.count+13)/14
        for idx in 0..<count {
            let p=SettingsPacket.receiver(cmd,sub:sub,count:count,index:idx,data:Array(data[idx*14..<min(data.count,idx*14+14)]))
            var ack=false
            for attempt in 0..<5 {
                if attempt>0 { progress(idx,count,true) }
                channel.drain(); try channel.send(p)
                let end=Date().addingTimeInterval(timeout)
                while Date()<end, let r=channel.receive(timeout:end.timeIntervalSinceNow) {
                    guard valid(r), r[1]&127==cmd else { continue }
                    if r[1]&128 != 0 { throw F65Error.nak(cmd) }
                    if Int(r[3])==idx && r[4]>>4==sub { ack=true;break }
                }
                if ack { break }
            }
            guard ack else { throw F65Error.timeout(cmd) }
            progress(idx+1,count,false)
        }
    }
    func valid(_ p: [UInt8]) -> Bool { p.count == 20 && p[0]==0x13 && ReceiverProtocol.checksum(p)==p[19] }
    public func sendLive(_ colors: [RGB], slots: [Int]) -> Bool {
        do { for (i,p) in ReceiverProtocol.reports(colors,slots:slots).enumerated() { if i>0 { Thread.sleep(forTimeInterval:0.002) }; try channel.send(p) }; return true } catch { return false }
    }
}
public final class CableTransport: Transport {
    public let kind = LinkKind.cable
    let send: ([UInt8]) throws -> Void
    let receive: () throws -> [UInt8]
    public init(send: @escaping ([UInt8]) throws -> Void, receive: @escaping () throws -> [UInt8]) { self.send=send;self.receive=receive }
    public func read(_ cmd: UInt8, sub: UInt8 = 0) throws -> [UInt8] {
        if cmd==7 { return [1] }
        guard [UInt8(0x41),0x43,0x44,0x49].contains(cmd), let m=Blocks.cableMap[cmd], sub==0 || (cmd==0x41 && sub==1) else { throw F65Error.invalid("Cable read unavailable.") }
        for _ in 0..<3 {
            do {
                try send(SettingsPacket.cable(m.cmd|128,sub:sub,length:m.len));Thread.sleep(forTimeInterval:0.02)
                let p=try receive()
                if p.count>=8+m.len, p[0]==6, p[1]==m.cmd|128, p[2]==sub, p[4]==1, p[5]==0, Int(p[6])|Int(p[7])<<8 == m.len { return Array(p[8..<8+m.len]) }
            } catch { if case F65Error.notPermitted = error { throw error } }
            Thread.sleep(forTimeInterval:0.07)
        }
        throw F65Error.incomplete(cmd)
    }
    public func write(_ cmd: UInt8, sub: UInt8 = 0, data: [UInt8], progress: WriteProgress) throws {
        try Blocks.validate(cmd,sub:sub,data)
        let m=Blocks.cableMap[cmd]!
        var p=SettingsPacket.cable(m.cmd,sub:sub,length:m.len);p.replaceSubrange(8..<8+data.count,with:data)
        try send(p);Thread.sleep(forTimeInterval:0.1);progress(1,1,false)
    }
    public func sendLive(_ colors: [RGB], slots: [Int]) -> Bool { do { try send(CableProtocol.frame(colors));return true } catch { return false } }
}
