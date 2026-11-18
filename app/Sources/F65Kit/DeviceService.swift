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
    /// 2.4G connection check in flight (see `pollStatus`), and how many went unanswered in a row.
    private var statusAskedAt:Date?
    private var statusMisses=0
    private var forceBlockingPoll=false
    /// When the cached lighting block last came from the keyboard (a read or a verified save).
    private var lightingReadAt=Date.distantPast
    /// The keyboard reports its own lighting change (an 0A report) about 3 s after the app saves one; that echo
    /// needs no re-read (the save was already read back), and re-reading would hold up the animation.
    private var ownLightingSaveAt=Date.distantPast
    /// After the keyboard stores settings it restarts its own effect (it fades in its saved Fixed colour) and
    /// ignores live frames for a moment. Re-send the live picture on every tick until then, so it takes over
    /// the moment the keyboard is ready instead of at the next 0.4 s keep-alive.
    private var burstUntil=Date.distantPast
    private var mapCache:(bytes:[UInt8],map:KeyMap)?
    private static let liveSlots=PhysicalKey.indices.flatMap{$0}
    /// F65_TRACE=1 prints frame gaps and save timings to stderr.
    private let trace=ProcessInfo.processInfo.environment["F65_TRACE"]=="1"
    private var traceWindow=(start:Date(),frames:0,maxGap:0.0,sendTotal:0.0,sendMax:0.0,reports:0)
    private func log(_ s:@autoclosure ()->String) {if trace {FileHandle.standardError.write((String(format:"[%.3f] ",Date().timeIntervalSince(startTime))+s()+"\n").data(using:.utf8)!)}}
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
        // 20 ticks a second with a tight leeway: the frame rate picked on the F65, without timer coalescing jitter.
        q.async {self.settings=s;self.hub?.start();let t=DispatchSource.makeTimerSource(flags:.strict,queue:self.q);t.schedule(deadline:.now(),repeating:.milliseconds(50),leeway:.milliseconds(2));t.setEventHandler{[weak service=self] in service?.tick()};self.timer=t;t.resume()}
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
        let began=Date()
        defer {state.busy=false;lastFrame=[];nextFrame=Date();statusAskedAt=nil;burstUntil=Date().addingTimeInterval(2);if !background {publish()};log("transaction \(background ? "poll":"save") \(Int(Date().timeIntervalSince(began)*1000)) ms")}
        // Live frames disturb 2.4G replies; only wait for them to settle when frames were just sent.
        // Cable reports are synchronous, so a short pause is enough there.
        if Date().timeIntervalSince(lastSend)<0.5 {Thread.sleep(forTimeInterval:t.kind == .receiver ? 0.15:0.03)}
        t.drain()
        let checkStart=Date();state.online = try t.read(7,sub:0).first==1;log("  connected check \(Int(Date().timeIntervalSince(checkStart)*1000)) ms")
        guard state.online else {state.snapshot=nil;throw F65Error.asleep}
        return try body(t)
    }
    private func keyMap(_ s:Snapshot)->KeyMap {
        if let c=mapCache,c.bytes==s.base.bytes {return c.map}
        let m=KeyMap(bytes:s.base.bytes) ?? KeyMap.fallback;mapCache=(s.base.bytes,m);return m
    }
    /// Whether live frames show with this lighting block (over 2.4G only while the saved effect is Fixed).
    private func streamable(_ t:Transport,_ led:LightingBlock)->Bool {settings.mode != .off && !settings.paused && (t.kind == .cable || led.effect==1)}
    private func send(_ t:Transport,_ frame:[RGB],snapshot:Snapshot)->Bool {
        let sendStart=Date()
        guard t.sendLive(frame,slots:Self.liveSlots,pinned:FrameRenderer.pinnedSlots(settings)) else {return false}
        if trace {let took=Date().timeIntervalSince(sendStart),gap=Date().timeIntervalSince(lastSend);traceWindow.frames+=1;traceWindow.sendTotal+=took;traceWindow.sendMax=max(traceWindow.sendMax,took)
            if t.kind == .receiver {traceWindow.reports+=ReceiverProtocol.reports(frame,slots:Self.liveSlots,pinned:FrameRenderer.pinnedSlots(settings)).count}
            if lastSend != .distantPast {traceWindow.maxGap=max(traceWindow.maxGap,gap)}
            if Date().timeIntervalSince(traceWindow.start)>=1 {let w=traceWindow;log("frames \(w.frames)/s, \(w.reports) reports, send avg \(Int(w.sendTotal/Double(max(1,w.frames))*1000)) max \(Int(w.sendMax*1000)) ms, longest gap \(Int(w.maxGap*1000)) ms");traceWindow=(Date(),0,0,0,0,0)}}
        lastFrame=frame;lastSend=Date();deliverFrame(frame);return true
    }
    private func load(_ t:Transport) throws {
        state.snapshot=try Snapshot(t);lightingReadAt=Date()
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
                        before=cached
                        // 2.4G lighting saves reuse the cached block (~10 packets saved per click) when it is known to
                        // match the keyboard: it was read or verified in the last minute, and no 0A report has
                        // announced a Fn-shortcut change since. Otherwise read it fresh.
                        let trusted=t.kind == .receiver && target.cmd==0x44 && Date().timeIntervalSince(self.lightingReadAt)<60 && !(self.hub?.statusChanged()==true && Date().timeIntervalSince(self.ownLightingSaveAt)>5)
                        let readStart=Date()
                        if !trusted {try before.replace(target.cmd,sub:target.sub,bytes:t.read(target.cmd,sub:target.sub));if target.cmd==0x44 {self.lightingReadAt=Date()}}
                        self.log("  read before save: \(trusted ? "skipped (cached)":"\(Int(Date().timeIntervalSince(readStart)*1000)) ms")")
                    } else {before=try Snapshot(t);self.lightingReadAt=Date()}
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
                        led.copySide(from:desired)
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
                                for off in LightingBlock.sideOffsets.values {safe.bytes[off]=record.bytes[off]}
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
                            let saveStart=Date();defer {self.log("  write + verify \(Int(Date().timeIntervalSince(saveStart)*1000)) ms")}
                            let back=try safeSave(t,cmd:r.cmd&15,sub:r.sub,new:r.bytes,old:old.bytes,backup:backup,checkAwake:false,progress:{a,_,resend in self.state.progress=completed+a;self.state.total=total;self.state.resend=resend;self.publish()})
                            try after.replace(r.cmd,sub:r.sub,bytes:back);if r.cmd==0x44 {self.lightingReadAt=Date();self.ownLightingSaveAt=Date()}
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
        let tickStart=Date()
        let statusReport=hub?.statusChanged()==true && Date().timeIntervalSince(ownLightingSaveAt)>5
        let streaming=transport.map{t in state.snapshot.map{streamable(t,$0.lighting)} ?? false} ?? false
        if let t=transport,t.kind == .receiver,state.online,state.snapshot != nil,!statusReport,!forceBlockingPoll,Date()<nextLightingRead {
            pollStatus(t)
        } else if Date()>=nextPoll || statusReport || forceBlockingPoll {
            forceBlockingPoll=false;statusAskedAt=nil
            nextPoll=Date().addingTimeInterval(state.online ? 5:2)
            let was=(state.snapshot,state.online,state.link,state.message,state.permissionDenied)
            do {
                try transaction(background:true) {t in
                    if state.snapshot==nil {try load(t)}
                    // Cable reads are one report, so follow Fn-shortcut changes every poll. Over 2.4G the keyboard
                    // announces them with a 0A report; otherwise re-check every 30 s (every 5 min while streaming,
                    // when the read would briefly hold up the animation).
                    else if t.kind == .cable || statusReport || Date()>=nextLightingRead {
                        state.snapshot?.lighting=try LightingBlock(t.read(0x44,sub:0));lightingReadAt=Date()
                    }
                    nextLightingRead=Date().addingTimeInterval(streaming ? 300:30)
                }
                state.permissionDenied=false
                if state.recovery==nil && state.progress==0 && state.snapshot != was.0 {state.message=isMock ? "Loaded from mock keyboard":"Loaded from keyboard"}
                if was.0 != state.snapshot || was.1 != state.online || was.2 != state.link || was.3 != state.message || was.4 != state.permissionDenied {publish()}
            } catch {handle(error)}
        }
        guard state.online,let t=transport,let snapshot=state.snapshot,streamable(t,snapshot.lighting) else {deliverFrame(nil);return}
        guard Date()>=nextFrame else{return}
        let frame=FrameRenderer.render(settings,map:keyMap(snapshot),time:Date().timeIntervalSince(startTime),receiver:t.kind == .receiver)
        // Send only when the picture changes, plus a keep-alive (the keyboard falls back to its saved effect ~1 s
        // after the last frame). Every tick may send: 20 frames/s with 2 ms between reports is the rate confirmed
        // smooth on the F65 over 2.4G.
        if frame==lastFrame && Date().timeIntervalSince(lastSend)<0.4 && Date()>=burstUntil {return}
        // Measured from the start of this tick, not the end of the send: a 2.4G frame takes ~20–30 ms to send, and
        // timing from its end made every other tick too early (10 frames/s instead of 20).
        if send(t,frame,snapshot:snapshot) {failures=0;nextFrame=tickStart.addingTimeInterval(0.04)}
        else {failures+=1;if failures>=20 {hub?.disconnect();transport=nil;state.snapshot=nil;state.online=false;nextPoll=Date().addingTimeInterval(2);publish()}}
    }
    /// 2.4G "is the keyboard still connected" check every 5 s without pausing the stream: the request goes out
    /// between frames and the reply is picked up on a later tick. Three unanswered requests in a row fall back
    /// to the blocking check, which also reopens a receiver that has gone silent.
    private func pollStatus(_ t:Transport) {
        if let asked=statusAskedAt {
            if let ok=t.takeStatusReply() {
                statusAskedAt=nil;statusMisses=0
                if !ok {handle(F65Error.asleep);nextPoll=Date().addingTimeInterval(2)}
            } else if Date().timeIntervalSince(asked)>1.5 {
                statusAskedAt=nil;statusMisses+=1;log("status request \(statusMisses) unanswered")
                if statusMisses>=3 {statusMisses=0;forceBlockingPoll=true} else {nextPoll=Date()}
            }
        } else if Date()>=nextPoll {
            do {try t.requestStatus();statusAskedAt=Date();nextPoll=Date().addingTimeInterval(5)} catch {forceBlockingPoll=true}
        }
    }
    private var frameShown=false
    /// Frames go to the UI as they are sent; "no frame" is sent once, not on every idle tick.
    private func deliverFrame(_ f:[RGB]?) {
        if f==nil {guard frameShown else {return}}
        frameShown = f != nil
        DispatchQueue.main.async {[onFrame] in onFrame?(f)}
    }
    private func publish() {
        let s=state;var e=EngineStatus();e.link=s.link;e.cablePresent=s.link == .cable;e.receiverPresent=s.link == .receiver
        e.streaming=s.online && !s.busy && !suspended && settings.mode != .off && !settings.paused && (s.link == .cable || s.snapshot?.lighting.effect==1)
        e.message=s.message;e.keyMapSource=s.snapshot==nil ? "built-in":"read from keyboard"
        if let snapshot=s.snapshot {e.unknownKeys=settings.layout.resolve(KeyMap(bytes:snapshot.base.bytes)!).unknown}
        DispatchQueue.main.async {[onState,onStatus] in onState?(s);onStatus?(e)}
    }
}
