import Foundation
public final class MockTransport: Transport {
    public var kind: LinkKind
    public var asleep=false
    public var failWrites=Set<Int>()
    public var corruptWrites=Set<Int>()
    public var writes=0
    public var liveFrames=0
    public var storage: [String:[UInt8]]
    public init(kind: LinkKind = .cable, records: [BackupRecord]? = nil) {
        self.kind=kind
        var led=[UInt8](repeating:0,count:128);led[10]=1;led[126]=0x5a;led[127]=0xa5
        for e in 1...18 {led[0x38+2*e]=4;led[0x39+2*e]=0x37};led[0x4e]=2;led[0x4f]=0x47
        var p=try! Palette([UInt8](repeating:0,count:490));p.reset()
        storage=["68:0":led,"73:0":p.bytes,"65:0":KeyMap.fallback.bytes,"65:1":KeyMap.parseHex("070000040700000408020000000000000000000007000013020000700000003a070000080000000000000000070000010200006f0000003b070000000000000000000000000000000004002b0000003c07000005000000000000000000000000000400290000003d07000006000000000000000000000000020002230000003e070000070700000a07000011000000000200018a0000003f00000000000000000000000000000000020000b60000004000000046000000000000000000000000020000cd0000004100000047000000000804000100000000020000b5000000420000004800000000080300010d000000020000e20000004300000000000000000802000100000000020000ea0000004400000000000000000000000000000000020000e90000004500000000000000000000000000000000000000000000000008000000000000000800000108040200000000000000000000000000000000000000005200000051000000000000004c0000004b0000004e0000004a08040100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),"67:0":[UInt8](repeating:0,count:512),"74:0":[100,16]]
        for r in records ?? [] {storage["\(r.cmd):\(r.sub)"]=r.bytes}
    }
    public func read(_ cmd: UInt8, sub: UInt8 = 0) throws -> [UInt8] {
        if cmd==7 {return [asleep ? 0 : 1]};if asleep {throw F65Error.asleep}
        guard let b=storage["\(cmd):\(sub)"] else {throw F65Error.timeout(cmd)};return b
    }
    public func write(_ cmd: UInt8, sub: UInt8 = 0, data: [UInt8], progress: WriteProgress) throws {
        try Blocks.validate(cmd,sub:sub,data);if asleep {throw F65Error.asleep};writes+=1
        if failWrites.contains(writes) {throw F65Error.nak(cmd)}
        var b=data;if corruptWrites.contains(writes) { b=b.map {$0 ^ 1} }
        storage["\(cmd|0x40):\(sub)"]=b
        let n=kind == .cable ? 1 : (data.count+13)/14
        for i in 1...n {progress(i,n,false)}
    }
    public func sendLive(_ colors: [RGB], slots: [Int]) -> Bool { liveFrames+=1; return !asleep }
}
// Packet-level mock: exercises the production receiver algorithm, including losses and retries.
public final class MockPacketChannel: PacketChannel {
    public let keyboard: MockTransport
    public var dropRead: [Int:Set<Int>]=[:]
    public var dropACK: [Int:Int]=[:]
    public var nak=false
    public var silence=false
    public var reverse=true
    public private(set) var readAttempts=0
    public private(set) var sent:[[UInt8]]=[]
    var inbox:[[UInt8]]=[];var partial:[Int:[UInt8]]=[:]
    public init(_ keyboard: MockTransport = MockTransport(kind:.receiver)) {self.keyboard=keyboard}
    public func send(_ p:[UInt8]) throws {
        sent.append(p);if silence {return}
        let c=p[1],s=p[4]>>4
        if nak {inbox.append(SettingsPacket.receiver(c|128,sub:s));return}
        if c==7 || c&0xf0==0x40 {
            readAttempts+=1;let b=try keyboard.read(c,sub:s);let n=(b.count+13)/14
            var packets=(0..<n).filter {!(dropRead[readAttempts] ?? []).contains($0)}.map {SettingsPacket.receiver(c,sub:s,count:n,index:$0,data:Array(b[$0*14..<min(b.count,$0*14+14)]))}
            if reverse {packets.reverse()};inbox+=packets
        } else if [UInt8(1),4,9].contains(c) {
            let i=Int(p[3]);partial[i]=Array(p[5..<5+Int(p[4]&15)])
            if partial.count==Int(p[2]) {let b=(0..<Int(p[2])).flatMap {partial[$0]!};try keyboard.write(c,sub:s,data:b,progress:{_,_,_ in});partial=[:]}
            if (dropACK[i] ?? 0)>0 {dropACK[i]!-=1;return};inbox.append(p)
        }
    }
    public func receive(timeout: TimeInterval) -> [UInt8]? { inbox.isEmpty ? nil : inbox.removeFirst() }
    public func drain() {inbox=[]}
}
