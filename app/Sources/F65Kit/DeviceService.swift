import Foundation

public struct DeviceState {
    public var snapshot: Snapshot?
    public var link: LinkKind?
    public var online=false
    public var busy=false
    public var message="Looking for keyboard…"
    public var permissionDenied=false
    public var battery: Int?
    public var macroBytes: [UInt8]?
    public var progress=0
    public var total=0
    public var resend=false
    public var recovery: URL?
    public init() {}
}
public enum DeviceEdit {
    case effect(Int), lighting(String,Int), palette([RGB]), paletteReset
    /// Several queued lighting choices in one save: copies the effect byte and the 18 per-effect
    /// slots (the only decoded lighting bytes) from `desired` onto a freshly read block.
    case lightingBlock(LightingBlock)
    case remap(slot:Int,layer:UInt8,entry:KeyEntry,allowProtected:Bool)
    case restore([BackupRecord]), backup, refresh
}
public final class DeviceService: @unchecked Sendable {
    private let q=DispatchQueue(label:"local.f65.lighting.io",qos:.userInitiated)
    private let hub: HIDHub?
    private let mock: MockTransport?
    public let backups: BackupStore
    private var timer:DispatchSourceTimer?
    private var settings=Settings()
    private var state=DeviceState()
    private var transport:Transport?
    private var suspended=false
    private var nextPoll=Date.distantPast
    private var nextLightingRead=Date.distantPast
    private var lastFrame:[RGB]=[]
    private var lastSend=Date.distantPast
    private var nextFrame=Date.distantPast
    private var failures=0
    private let startTime=Date()
    public var onState:((DeviceState)->Void)?
    public var onStatus:((EngineStatus)->Void)?
    public var onFrame:(([RGB]?)->Void)?
    public init(mock:MockTransport? = nil, backups:BackupStore? = nil) {
        let useMock=mock != nil || ProcessInfo.processInfo.environment["F65_MOCK"]=="1"
        self.mock=mock ?? (useMock ? MockTransport() : nil)
        hub=useMock ? nil : HIDHub()
        self.backups=backups ?? BackupStore(directory:useMock ? AppPaths.supportDir.appendingPathComponent("mock-backups") : AppPaths.supportDir.appendingPathComponent("backups"))
    }
    public var isMock:Bool {mock != nil}
    public func start(with s:Settings) {
        q.async {self.settings=s;self.hub?.start();let t=DispatchSource.makeTimerSource(queue:self.q);t.schedule(deadline:.now(),repeating:0.05);t.setEventHandler{[weak service=self] in service?.tick()};self.timer=t;t.resume()}
    }
    public func update(_ s:Settings) {q.async {if s.pref != self.settings.pref {self.hub?.disconnect();self.transport=nil;self.state.snapshot=nil;self.nextPoll = .distantPast};self.settings=s;self.lastFrame=[];self.publish()}}
    public func setSuspended(_ value:Bool) {q.async {self.suspended=value;self.nextPoll = .distantPast;self.publish();if value {self.deliverFrame(nil)}}}
    public func stop() {q.sync {timer?.cancel();timer=nil;hub?.stop()}}
    private func connect() throws -> Transport {
        let t:Transport
        if let mock {mock.kind=settings.pref == .receiver ? .receiver : .cable;t=mock}
        else {t=try hub!.connection(preference:settings.pref.rawValue)}
        if transport !== t {transport=t;state.snapshot=nil;state.battery=nil;state.macroBytes=nil}
        state.link=t.kind;return t
    }
    // Called only on q. While this synchronous transaction runs the frame timer cannot fire;
    // HID callbacks are on HIDHub.callbacks and feed the independently locked inbox.
    // Background transactions (the periodic poll) don't mark the app busy and don't publish unless
    // something changed, so the window never flickers into a disabled state every few seconds.
    private func transaction<T>(background:Bool=false,_ body:(Transport)throws->T) throws -> T {
        let t=try connect()
        if !background {state.busy=true;publish()}
        defer {state.busy=false;lastFrame=[];nextFrame=Date();if !background {publish()}}
        // Live frames disturb replies; only wait for them to settle when frames were just sent.
        if Date().timeIntervalSince(lastSend)<0.5 {Thread.sleep(forTimeInterval:0.15)}
        t.drain()
        state.online = try t.read(7,sub:0).first==1
        guard state.online else {state.snapshot=nil;throw F65Error.asleep}
        return try body(t)
    }
    private func load(_ t:Transport) throws {
        state.snapshot=try Snapshot(t)
        if t.kind == .receiver {state.battery=(try? t.read(0x4a,sub:0))?.first.map(Int.init)}
        state.macroBytes=try? t.read(0x43,sub:0)
        if let s=state.snapshot {KeyMap(bytes:s.base.bytes)?.saveToCache()}
    }
    public func perform(_ edit:DeviceEdit, completion:((Result<URL?,Error>)->Void)? = nil) {
        q.async {
            do {
                self.state.progress=0;self.state.total=0;self.state.recovery=nil
                let result:URL? = try self.transaction {t in
                    if case .refresh=edit {try self.load(t);return nil}
                    // Read fresh only the block being changed (2.4G: ~10 packets for lighting instead of
                    // ~117 for everything). Restores and explicit backups still read all four blocks.
                    var before:Snapshot
                    if let cached=self.state.snapshot,let target=Self.target(edit) {
                        before=cached;try before.replace(target.cmd,sub:target.sub,bytes:t.read(target.cmd,sub:target.sub))
                    } else {before=try Snapshot(t)}
                    self.state.snapshot=before
                    let backup=try self.backups.write(before)
                    if case .backup=edit {return backup}
                    var records:[BackupRecord]=[]
                    var led=before.lighting;var palette=before.palette
                    switch edit {
                    case .effect(let e): try led.setEffect(e);records=[.init(cmd:0x44,sub:0,bytes:led.bytes)]
                    case .lighting(let field,let value):try led.set(field,value:value);records=[.init(cmd:0x44,sub:0,bytes:led.bytes)]
                    case .lightingBlock(let desired):
                        try led.setEffect(desired.effect)
                        for e in 1...18 {try led.setSlot(e,brightness:desired.brightness(e),speed:desired.speed(e),colour:desired.colour(e))}
                        records=[.init(cmd:0x44,sub:0,bytes:led.bytes)]
                    case .palette(let colors):guard colors.count==7 else{throw F65Error.invalid("Seven palette colours required.")};for (i,c) in colors.enumerated(){try palette.set(i,c)};records=[.init(cmd:0x49,sub:0,bytes:palette.bytes)]
                    case .paletteReset:palette.reset();records=[.init(cmd:0x49,sub:0,bytes:palette.bytes)]
                    case .remap(let slot,let layer,let entry,let allow):
                        guard layer<=1 else{throw F65Error.invalid("Invalid layer.")}
                        var keys=layer==0 ? before.base:before.fn;try keys.set(slot,entry,allowProtected:allow);records=[.init(cmd:0x41,sub:layer,bytes:keys.bytes)]
                    case .restore(let r):
                        records=try r.map { record in
                            guard let previous=before.records.first(where:{$0.cmd==record.cmd && $0.sub==record.sub}) else {throw F65Error.invalid("Unknown restore block.")}
                            var safe=record
                            if record.cmd==0x44 {
                                try Blocks.validate(4,sub:record.sub,record.bytes)
                                // Undecoded LED fields are never editable, even via an import.
                                safe.bytes=previous.bytes
                                safe.bytes[10]=record.bytes[10]
                                for e in 1...18 {safe.bytes[0x38+2*e]=record.bytes[0x38+2*e];safe.bytes[0x39+2*e]=record.bytes[0x39+2*e]}
                            } else if record.cmd==0x49,record.bytes.count==490 {safe.bytes.replaceSubrange(483..<490,with:previous.bytes[483..<490])}
                            return safe
                        }
                    default:break
                    }
                    // Validate the entire restore before the first write, including duplicate blocks.
                    var seen=Set<String>()
                    for r in records {guard [UInt8(0x41),0x44,0x49].contains(r.cmd),seen.insert("\(r.cmd):\(r.sub)").inserted else{throw F65Error.invalid("Invalid restore records.")};try Blocks.validate(r.cmd&15,sub:r.sub,r.bytes)}
                    let total=records.reduce(0){$0+(t.kind == .cable ? 1:($1.bytes.count+13)/14)};var completed=0
                    var applied:[BackupRecord]=[]
                    var after=before
                    do {
                        for r in records {
                            let old=before.records.first{$0.cmd==r.cmd && $0.sub==r.sub}!
                            self.state.message="Saving and verifying…";self.publish()
                            let back=try safeSave(t,cmd:r.cmd&15,sub:r.sub,new:r.bytes,old:old.bytes,backup:backup){a,_,resend in self.state.progress=completed+a;self.state.total=total;self.state.resend=resend;self.publish()}
                            try after.replace(r.cmd,sub:r.sub,bytes:back)
                            applied.append(old);completed += t.kind == .cable ? 1:(r.bytes.count+13)/14
                        }
                    } catch {
                        // Multi-block restore is a single user operation. Revert earlier successful
                        // blocks too, each with a fresh backup and verified safeSave.
                        var allRolledBack=true
                        if case F65Error.verifyFailed(let ok,_)=error {allRolledBack=ok}
                        for old in applied.reversed() {
                            do {let current=try Snapshot(t);let undoBackup=try self.backups.write(current);let b=current.records.first{$0.cmd==old.cmd && $0.sub==old.sub}!.bytes
                                _ = try safeSave(t,cmd:old.cmd&15,sub:old.sub,new:old.bytes,old:b,backup:undoBackup)
                            } catch {allRolledBack=false}
                        }
                        if !applied.isEmpty {throw F65Error.verifyFailed(rolledBack:allRolledBack,backup:backup)}
                        throw error
                    }
                    // The verified read-back is the new state; no full re-read needed except after a restore.
                    if case .restore=edit {try self.load(t)} else {
                        self.state.snapshot=after
                        if after.base != before.base {KeyMap(bytes:after.base.bytes)?.saveToCache()}
                    }
                    return backup
                }
                self.state.message = self.isMock ? "Verified against mock keyboard" : "Loaded from keyboard · saved and verified"
                if case .backup=edit {self.state.message="Restore point saved"}
                if case .refresh=edit {self.state.message=self.isMock ? "Loaded from mock keyboard":"Loaded from keyboard"}
                self.publish();DispatchQueue.main.async {completion?(.success(result))}
            } catch {
                self.handle(error);DispatchQueue.main.async {completion?(.failure(error))}
            }
        }
    }
    /// The single block an edit changes, or nil when it needs a full snapshot.
    static func target(_ edit:DeviceEdit)->(cmd:UInt8,sub:UInt8)? {
        switch edit {
        case .effect,.lighting,.lightingBlock: return (0x44,0)
        case .palette,.paletteReset: return (0x49,0)
        case .remap(_,let layer,_,_): return (0x41,layer)
        default: return nil
        }
    }
    private func handle(_ error:Error) {
        state.message=error.localizedDescription
        state.permissionDenied = {if case F65Error.notPermitted=error{return true};return false}()
        if case F65Error.verifyFailed(let rolled,let url)=error {state.recovery=rolled ? nil:url;state.snapshot=nil}
        if case F65Error.notFound=error {state.link=nil;state.online=false;state.snapshot=nil;transport=nil}
        if case F65Error.asleep=error {state.online=false;state.snapshot=nil}
        publish()
    }
    private func tick() {
        guard !suspended else{return}
        let statusReport=hub?.statusChanged()==true
        if Date()>=nextPoll || statusReport {
            nextPoll=Date().addingTimeInterval(state.online ? 5:2)
            let was=(state.snapshot,state.online,state.link,state.message,state.permissionDenied)
            do {
                try transaction(background:true) {t in
                    if state.snapshot==nil {try load(t)}
                    // Cable reads are one report, so follow Fn-shortcut changes every poll. Over 2.4G the
                    // keyboard announces them with a 0A report; otherwise re-check every 30 s.
                    else if t.kind == .cable || statusReport || Date()>=nextLightingRead {
                        state.snapshot?.lighting=try LightingBlock(t.read(0x44,sub:0));nextLightingRead=Date().addingTimeInterval(30)
                    }
                }
                state.permissionDenied=false
                if state.recovery==nil && state.progress==0 && state.snapshot != was.0 {state.message=isMock ? "Loaded from mock keyboard":"Loaded from keyboard"}
                if was.0 != state.snapshot || was.1 != state.online || was.2 != state.link || was.3 != state.message || was.4 != state.permissionDenied {publish()}
            } catch {handle(error)}
        }
        guard settings.mode != .off,!settings.paused,state.online,let t=transport,let snapshot=state.snapshot else {deliverFrame(nil);return}
        guard t.kind == .cable || snapshot.lighting.effect==1 else{deliverFrame(nil);return}
        guard Date()>=nextFrame else{return}
        let frame=FrameRenderer.render(settings,map:KeyMap(bytes:snapshot.base.bytes)!,time:Date().timeIntervalSince(startTime),receiver:t.kind == .receiver)
        if t.kind == .receiver && frame==lastFrame && Date().timeIntervalSince(lastSend)<0.4 {return}
        if t.sendLive(frame,slots:PhysicalKey.indices.flatMap{$0}) {
            failures=0;lastFrame=frame;lastSend=Date()
            let reports=t.kind == .receiver ? ReceiverProtocol.reports(frame,slots:PhysicalKey.indices.flatMap{$0}).count : 1
            nextFrame=Date().addingTimeInterval(t.kind == .receiver ? max(0.05,Double(reports)/70):0.05)
            deliverFrame(frame)
        } else {failures+=1;if failures>=20 {hub?.disconnect();transport=nil;state.snapshot=nil;state.online=false;nextPoll=Date().addingTimeInterval(2);publish()}}
    }
    private func deliverFrame(_ f:[RGB]?) {DispatchQueue.main.async {[onFrame] in onFrame?(f)}}
    private func publish() {
        let s=state;var e=EngineStatus();e.link=s.link;e.cablePresent=s.link == .cable;e.receiverPresent=s.link == .receiver
        e.streaming=s.online && !s.busy && !suspended && settings.mode != .off && !settings.paused && (s.link == .cable || s.snapshot?.lighting.effect==1)
        e.message=s.message;e.keyMapSource=s.snapshot==nil ? "built-in":"read from keyboard"
        if let snapshot=s.snapshot {e.unknownKeys=settings.layout.resolve(KeyMap(bytes:snapshot.base.bytes)!).unknown}
        DispatchQueue.main.async {[onState,onStatus] in onState?(s);onStatus?(e)}
    }
}
