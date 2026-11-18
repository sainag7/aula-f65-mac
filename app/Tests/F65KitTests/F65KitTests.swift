import XCTest
@testable import F65Kit
final class F65KitTests: XCTestCase {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func fixture() throws -> [BackupRecord] {try BackupStore().load(root.appendingPathComponent("backups/f65-20261117-042024.txt"))}
    func testPacketHeadersAndMap() throws {
        let p=SettingsPacket.receiver(4,sub:0,count:10,index:9,data:[0x5a,0xa5])
        XCTAssertEqual(Array(p.prefix(7)),[0x13,4,10,9,2,0x5a,0xa5]);XCTAssertEqual(p[19],ReceiverProtocol.checksum(p))
        XCTAssertEqual(Array(SettingsPacket.cable(0x83,sub:1,length:504).prefix(8)),[6,0x83,1,0,1,0,0xf8,1])
        XCTAssertEqual(Blocks.cableMap[0x49]?.len,490);XCTAssertEqual(Blocks.cableMap[0x41]?.cmd,3)
        XCTAssertEqual(Array(CableProtocol.frame([.black]).prefix(8)),[6,8,0,0,1,0,0x7a,1])
    }
    func testReceiverOutOfOrderAndMergedDrops() throws {
        let c=MockPacketChannel();c.dropRead=[1:[0,3,8],2:[1,2,4,5,6,7,9]]
        XCTAssertEqual(try ReceiverTransport(c).read(0x44),try c.keyboard.read(0x44));XCTAssertEqual(c.readAttempts,2)
    }
    func testReceiverNAKTimeoutIncompleteAndChecksum() throws {
        let c=MockPacketChannel();let t=ReceiverTransport(c);t.tries=2
        c.nak=true;XCTAssertThrowsError(try t.read(0x44)) {guard case F65Error.nak = $0 else {return XCTFail()}}
        c.nak=false;c.silence=true;XCTAssertThrowsError(try t.read(0x44)) {guard case F65Error.timeout = $0 else {return XCTFail()}}
        c.silence=false;c.dropRead=[1:[0],2:[0]];XCTAssertThrowsError(try t.read(0x44)) {guard case F65Error.incomplete = $0 else {return XCTFail()}}
        var bad=SettingsPacket.receiver(4,sub:0);bad[19] ^= 1;XCTAssertFalse(t.valid(bad))
    }
    func testACKResendAndNAK() throws {
        let c=MockPacketChannel();c.dropACK=[2:1];let t=ReceiverTransport(c);let b=try c.keyboard.read(0x44)
        var ack:[Int]=[];var resend=false
        try t.write(4,data:b) {i,n,r in XCTAssertEqual(n,10);if r {resend=true}else{ack.append(i)}}
        XCTAssertEqual(ack,Array(1...10));XCTAssertTrue(resend);XCTAssertEqual(c.sent.count,11)
        c.nak=true;XCTAssertThrowsError(try t.write(4,data:b,progress:{_,_,_ in}))
    }
    func testAllowlistAndSizes() throws {
        let c=MockPacketChannel();let t=ReceiverTransport(c)
        for cmd:UInt8 in [0,2,3,6,8,10,11,0x88] {XCTAssertThrowsError(try t.write(cmd,data:[0],progress:{_,_,_ in}))}
        XCTAssertTrue(c.sent.isEmpty)
        XCTAssertThrowsError(try Blocks.validate(4,sub:0,[UInt8](repeating:0,count:128)))
        XCTAssertThrowsError(try Blocks.validate(1,sub:2,[UInt8](repeating:0,count:504)))
    }
    func testLightingFixtureAndPreservation() throws {
        let original=try fixture().first {$0.cmd==0x44}!.bytes;var l=try LightingBlock(original)
        XCTAssertEqual(l.brightness(11),2);XCTAssertEqual(l.speed(11),4);XCTAssertEqual(l.colour(11),7)
        try l.setEffect(11);try l.set("speed",value:2);XCTAssertEqual(l.colour(11),7)
        try l.set("colour",value:3);XCTAssertEqual(l.speed(11),2)
        try l.set("brightness",value:0);XCTAssertEqual(l.brightness(11),0)
        XCTAssertEqual(Array(l.bytes.prefix(10)),Array(original.prefix(10)));XCTAssertEqual(l.bytes.suffix(2),[0x5a,0xa5])
        XCTAssertThrowsError(try l.setEffect(21));XCTAssertThrowsError(try l.set("brightness",value:5))
    }
    func testPaletteAllGroupsAndTrailer() throws {
        let b=try BackupStore().load(root.appendingPathComponent("backups/palette-factory.txt"))[0].bytes
        var p=try Palette(b);p.reset();XCTAssertEqual(p.bytes,b)
        try p.set(2,RGB(r:12,g:34,b:56))
        for g in 0..<23 {XCTAssertEqual(Array(p.bytes[g*21+6..<g*21+9]),[12,34,56])}
        XCTAssertEqual(p.bytes.suffix(7),b.suffix(7));XCTAssertThrowsError(try p.set(7,.black))
    }
    func testPhysicalMapAndEntries() throws {
        XCTAssertEqual(PhysicalKey.ids.count,67);XCTAssertEqual(Set(PhysicalKey.slots.values).count,67)
        let aliases=["lwin":"lcmd","lbr":"[","rbr":"]","bslash":"\\","semi":";"]
        for id in PhysicalKey.ids {
            let name=id.hasPrefix("d") && id.count==2 ? String(id.dropFirst()) : aliases[id] ?? id
            XCTAssertEqual(KeyMap.fallback.entry(PhysicalKey.slots[id]!),KeyMap.entry(forName:name),id)
            XCTAssertNotEqual(PhysicalKey.slots[id]! % 6,0)
        }
        for r in try fixture().filter({$0.cmd==0x41}) {for s in 0..<126 {let b=Array(r.bytes[s*4..<s*4+4]);XCTAssertEqual(KeyEntry(b).bytes,b);XCTAssertFalse(KeyEntry(b).description.isEmpty)}}
        var l=try KeyLayer(KeyMap.fallback.bytes);XCTAssertThrowsError(try l.set(59,KeyEntry.named("a")!))
        try l.set(9,KeyEntry.named("mute")!);XCTAssertEqual(l.entry(9).bytes,[2,0,0,0xe2]);XCTAssertEqual(l.entry(0).bytes,[0,0,0,0x29])
    }
    func testAllBackupsAndStrictParser() throws {
        for url in try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("backups"),includingPropertiesForKeys:nil) where url.pathExtension=="txt" {XCTAssertFalse(try BackupStore().load(url).isEmpty)}
        XCTAssertThrowsError(try BackupStore.parse("43 0 00"));XCTAssertThrowsError(try BackupStore.parse(""))
        let m=MockTransport(records:try fixture());let s=try Snapshot(m);let store=BackupStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer {try? FileManager.default.removeItem(at:store.directory)}
        let url=try store.write(s);XCTAssertEqual(try store.load(url),s.records);XCTAssertEqual(store.list().map { $0.resolvingSymlinksInPath() },[url.resolvingSymlinksInPath()])
    }
    func runSave(corrupt:Set<Int>,fail:Set<Int>=[]) throws -> (MockTransport,URL,[UInt8]) {
        let m=MockTransport();m.corruptWrites=corrupt;m.failWrites=fail
        let s=try Snapshot(m),store=BackupStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));let url=try store.write(s)
        var l=s.lighting;try l.setEffect(11)
        do {let back=try safeSave(m,cmd:4,new:l.bytes,old:s.lighting.bytes,backup:url);return (m,url,back)} catch {try? FileManager.default.removeItem(at:store.directory);throw error}
    }
    func testSafeSaveSuccessAndRetry() throws {
        for corrupt:Set<Int> in [[],[1]] {let (m,url,b)=try runSave(corrupt:corrupt);defer{try? FileManager.default.removeItem(at:url.deletingLastPathComponent())};XCTAssertEqual(b[10],11);XCTAssertEqual(m.writes,corrupt.isEmpty ? 1:2)}
    }
    func testVerifiedRollbackAndFailureURL() throws {
        XCTAssertThrowsError(try runSave(corrupt:[1,2])) {guard case F65Error.verifyFailed(let rolled,_) = $0 else {return XCTFail()};XCTAssertTrue(rolled)}
        XCTAssertThrowsError(try runSave(corrupt:[1,2,3,4])) {guard case F65Error.verifyFailed(let rolled,let url) = $0 else {return XCTFail()};XCTAssertFalse(rolled);XCTAssertEqual(url.pathExtension,"txt")}
    }
    func testBackupRequiredAndAsleep() throws {
        let m=MockTransport(kind:.receiver),s=try Snapshot(MockTransport());var l=s.lighting;try l.setEffect(2)
        XCTAssertThrowsError(try safeSave(m,cmd:4,new:l.bytes,old:s.lighting.bytes,backup:URL(fileURLWithPath:"/missing")));XCTAssertEqual(m.writes,0)
        let store=BackupStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));defer{try? FileManager.default.removeItem(at:store.directory)}
        let url=try store.write(s);m.asleep=true
        XCTAssertThrowsError(try safeSave(m,cmd:4,new:l.bytes,old:s.lighting.bytes,backup:url));XCTAssertEqual(m.writes,0)
    }
    func testLiveBudgetAndStableOrdering() {
        let colors: [RGB]=(0..<126).map { (i: Int) -> RGB in
            let r=UInt8(i*37%256);let g=UInt8(i*79%256);let b=UInt8(i*13%256);return RGB(r:r,g:g,b:b)
        }
        let p=ReceiverProtocol.reports(colors,slots:KeyMap.fallback.litSlots)
        XCTAssertLessThanOrEqual(p.count,12);XCTAssertEqual(p,ReceiverProtocol.reports(colors,slots:KeyMap.fallback.litSlots))
        for r in p {XCTAssertEqual(r.count,20);XCTAssertEqual(r[19],ReceiverProtocol.checksum(r))}
    }
}

final class DeviceServiceTests: XCTestCase {
    func testSerializedTransactionsAndFreshBackups() throws {
        let m=MockTransport();let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=BackupStore(directory:dir);let service=DeviceService(mock:m,backups:store)
        defer {service.stop();try? FileManager.default.removeItem(at:dir)}
        let done=expectation(description:"Both edits verified");done.expectedFulfillmentCount=2
        service.perform(.effect(11)){r in if case .failure(let e)=r{XCTFail(e.localizedDescription)};done.fulfill()}
        service.perform(.lighting("brightness",1)){r in if case .failure(let e)=r{XCTFail(e.localizedDescription)};done.fulfill()}
        wait(for:[done],timeout:5)
        let led=try LightingBlock(m.read(0x44));XCTAssertEqual(led.effect,11);XCTAssertEqual(led.brightness(11),1)
        XCTAssertEqual(store.list().count,2);XCTAssertEqual(m.liveFrames,0)
    }
    func testFailedRestoreRevertsEarlierBlocks() throws {
        let m=MockTransport();let original=try Snapshot(m);var led=original.lighting;try led.setEffect(11)
        var palette=original.palette;try palette.set(0,.black)
        m.failWrites=[2,3]
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service=DeviceService(mock:m,backups:BackupStore(directory:dir));defer{service.stop();try? FileManager.default.removeItem(at:dir)}
        let done=expectation(description:"Restore reverted")
        service.perform(.restore([.init(cmd:0x44,sub:0,bytes:led.bytes),.init(cmd:0x49,sub:0,bytes:palette.bytes)])){r in
            guard case .failure(let error)=r,case F65Error.verifyFailed(let rolled,_)=error else{XCTFail();done.fulfill();return};XCTAssertTrue(rolled);done.fulfill()
        }
        wait(for:[done],timeout:5);XCTAssertEqual(try Snapshot(m),original)
    }
    func testSingleBlockSaveReadsOnlyThatBlock() throws {
        let m=MockTransport(kind:.receiver);let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service=DeviceService(mock:m,backups:BackupStore(directory:dir));defer{service.stop();try? FileManager.default.removeItem(at:dir)}
        let loaded=expectation(description:"loaded");service.perform(.refresh){_ in loaded.fulfill()};wait(for:[loaded],timeout:5)
        m.readLog=[]
        let saved=expectation(description:"saved");service.perform(.effect(18)){r in if case .failure(let e)=r{XCTFail(e.localizedDescription)};saved.fulfill()}
        wait(for:[saved],timeout:5)
        XCTAssertFalse(m.readLog.contains(0x49));XCTAssertFalse(m.readLog.contains(0x41));XCTAssertFalse(m.readLog.contains(0x43))
        XCTAssertEqual(try LightingBlock(m.read(0x44)).effect,18)
    }
    func testQueuedLightingBlockAppliesEveryChoice() throws {
        let m=MockTransport();let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service=DeviceService(mock:m,backups:BackupStore(directory:dir));defer{service.stop();try? FileManager.default.removeItem(at:dir)}
        var desired=try LightingBlock(m.read(0x44));try desired.setEffect(6);try desired.set("brightness",value:2);try desired.set("colour",value:3)
        let saved=expectation(description:"saved");service.perform(.lightingBlock(desired)){r in if case .failure(let e)=r{XCTFail(e.localizedDescription)};saved.fulfill()}
        wait(for:[saved],timeout:5)
        let led=try LightingBlock(m.read(0x44));XCTAssertEqual(led.effect,6);XCTAssertEqual(led.brightness(6),2);XCTAssertEqual(led.colour(6),3);XCTAssertEqual(m.writes,1)
    }
    func testHiddenRowsMaskedAfterRemap() {
        var s=Settings();s.mode = .solid
        let f=FrameRenderer.render(s,map:KeyMap.fallback,time:0,receiver:false)
        for slot in stride(from:0,to:126,by:6) {XCTAssertEqual(f[slot],.black)}
        XCTAssertEqual(f[75],.black);XCTAssertNotEqual(f[9],.black)
    }
}
