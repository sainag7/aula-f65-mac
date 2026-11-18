import AppKit
import SwiftUI
import F65Kit

@MainActor final class AppModel: ObservableObject {
    let service:DeviceService
    var preferences:UserDefaults {service.isMock ? UserDefaults(suiteName:"local.f65.lighting.mock")! : .standard}
    @Published var device=DeviceState()
    @Published var live=F65Kit.Settings()
    @Published var pending=false
    @Published var section="Looks"
    @Published var hover:Int?
    @Published var selected:String?="esc"
    @Published var layer=0
    /// Latest live frame. Deliberately not @Published: it changes 20 times a second and only the keyboard
    /// preview draws it, so it goes straight to that view instead of re-rendering the whole window.
    var frame:[RGB]? {didSet {if previewLook==nil {liveFrameTarget?.liveFrame(frame)};if (frame != nil) != showingLiveFrame {showingLiveFrame = frame != nil}}}
    @Published var showingLiveFrame=false
    weak var liveFrameTarget:KeyboardView.Coordinator?
    @Published var points:[URL]=[]
    @Published var initial:Snapshot?
    @Published var verifiedKey:String?
    @Published var webFailure=false
    @Published var active=true
    var onLive:((F65Kit.Settings)->Void)?
    var onLogin:(()->Void)?
    var onEditLayout:(()->Void)?
    var onReloadLayout:(()->Void)?
    var busy:Bool {pending || device.busy || lightingDue}
    // Controls stay enabled while a save runs; further clicks are queued instead of greying the window.
    var canWrite:Bool {device.online && device.snapshot != nil}
    /// Lighting shown in the UI: the user's latest choice right away, before the keyboard confirms it.
    @Published var optimistic:LightingBlock?
    var lighting:LightingBlock? {optimistic ?? device.snapshot?.lighting}
    var palette:[RGB] {device.snapshot?.palette.colours ?? Palette.factory}
    private var queue:[(DeviceEdit,String?)]=[]

    // MARK: Looks
    let looks:LookStore
    @Published var lookList:[Look]=[]
    @Published var currentLookID:String? {didSet {preferences.set(currentLookID,forKey:"currentLook")}}
    /// Look waiting for the keyboard to wake (or connect).
    @Published var waitingLook:Look?
    @Published var toast:Toast?
    @Published var commandBar=false
    private var undoStack:[UndoState]=[]
    var canUndo:Bool {!undoStack.isEmpty}
    struct Toast:Equatable {var text:String;var undo:Bool;var id=UUID()}
    struct UndoState {let lighting:LightingBlock?;let live:F65Kit.Settings;let lookID:String?}

    init(service:DeviceService) {
        self.service=service
        looks=LookStore()
        lookList=looks.looks
        currentLookID=(service.isMock ? UserDefaults(suiteName:"local.f65.lighting.mock")! : .standard).string(forKey:"currentLook")
        service.onState={[weak self] state in MainActor.assumeIsolated {
            guard let self else{return}
            self.device=state
            if self.initial==nil {self.initial=state.snapshot}
            if self.canWrite,let w=self.waitingLook {self.waitingLook=nil;self.apply(w,recordUndo:false);self.show("Your F65 is awake. Applied \(w.name).")}
            self.tryOnUpdate()
        }}
        service.onFrame={[weak self] frame in MainActor.assumeIsolated {self?.frame=frame}}
        refreshPoints()
    }
    func edit(_ action:DeviceEdit, key:String?=nil) {
        hover=nil
        // Show lighting changes immediately; the keyboard catches up in the background.
        if var led=lighting {
            switch action {
            case .effect(let e): if (try? led.setEffect(e)) != nil {optimistic=led}
            case .lighting(let f,let v): if (try? led.set(f,value:v)) != nil {optimistic=led}
            default: break
            }
        }
        // The keyboard turns all its lights off for a moment whenever it stores lighting settings, so a burst of
        // lighting clicks (browsing side-light colours, say) is saved once, shortly after the last click.
        if Self.isLighting(action),optimistic != nil {scheduleLighting(key);return}
        if pending {queue.append((action,key));return}
        run(action,key:key)
    }
    /// Save a whole lighting block (a keyboard look), through the same settle-then-save path as single clicks.
    func setLighting(_ block:LightingBlock) {hover=nil;optimistic=block;scheduleLighting(nil)}
    private func scheduleLighting(_ key:String?) {
        lightingTimer?.invalidate();lightingDue=true
        let t=Timer(timeInterval:Self.lightingSettle,repeats:false){[weak self] _ in MainActor.assumeIsolated {self?.commitLighting(key)}}
        RunLoop.main.add(t,forMode:.common);lightingTimer=t   // .common: fires during menu tracking too
    }
    static let lightingSettle:TimeInterval=0.4
    private var lightingTimer:Timer?
    @Published private(set) var lightingDue=false
    private func commitLighting(_ key:String?) {
        lightingTimer=nil;lightingDue=false
        guard let desired=optimistic else{return}
        let action=DeviceEdit.lightingBlock(desired)
        if pending {queue.removeAll{Self.isLighting($0.0)};queue.append((action,key))} else {run(action,key:key)}
    }
    private static func isLighting(_ e:DeviceEdit)->Bool {switch e {case .effect,.lighting,.lightingBlock:return true;default:return false}}
    private func run(_ action:DeviceEdit,key:String?) {
        pending=true
        service.perform(action){[weak self] result in MainActor.assumeIsolated {
            guard let self else{return};self.refreshPoints()
            if case .success=result {self.verifiedKey=key}
            if !self.queue.isEmpty {let next=self.queue.removeFirst();self.run(next.0,key:next.1);return}
            // Keep showing the user's choice while another lighting save is still waiting to go out.
            self.pending=false;if !self.lightingDue {self.optimistic=nil}
        }}
    }
    func updateLive(_ change:(inout F65Kit.Settings)->Void) {var value=live;change(&value);live=value;onLive?(value)}

    // MARK: Applying looks

    var liveActive:Bool {live.mode != .off && !live.paused}
    /// What the keyboard shows now, as a look. Built-in and saved looks are recognised; anything else is described.
    var currentLook:Look? {
        if liveActive {
            if let l=looks.look(currentLookID),l.kind == .app {return l}
            return Look.fromLive(live,name:"Live lighting")
        }
        guard let led=lighting else {return looks.look(currentLookID)}
        if let l=looks.look(currentLookID),l.matches(led) {return l}
        return looks.matching(led) ?? Look.capture(led)
    }
    func reloadLooks() {lookList=looks.looks}

    func apply(_ look:Look,recordUndo:Bool=true) {
        previewLook=nil
        guard device.link != nil else {show("Connect your F65 to apply \(look.name).");return}
        if !canWrite && look.kind == .keyboard {waitingLook=look;show("\(look.name) will apply when your F65 wakes.");return}
        if recordUndo {pushUndo()}
        switch look.kind {
        case .keyboard:
            guard let led=lighting,let desired=try? look.applied(to:led) else {return}
            if liveActive {updateLive{$0=look.liveSettings($0)}}
            if desired != led {setLighting(desired)}
        case .app:
            if device.link == .receiver,let led=lighting,led.effect != 1,canWrite,askToSetFixed(look) {
                var b=led;try? b.setEffect(1);setLighting(b)
            }
            updateLive{$0=look.liveSettings($0)}
        }
        currentLookID=look.id
        show("Applied \(look.name)",undo:recordUndo)
    }
    /// Over 2.4G the keyboard only shows app-drawn lighting while its saved effect is Fixed. Asks once.
    private func askToSetFixed(_ look:Look)->Bool {
        if preferences.bool(forKey:"alwaysSetFixed") {return true}
        if service.isMock && ProcessInfo.processInfo.environment["F65_SMOKE"]=="1" {return true}
        let a=NSAlert();a.messageText="\(look.name) is drawn by this app"
        a.informativeText="Over 2.4G the F65 only shows app-drawn lighting while its saved effect is Fixed. Set the saved effect to Fixed now? That's one lighting save. Over the USB cable this isn't needed."
        a.addButton(withTitle:"Set to Fixed and apply");a.addButton(withTitle:"Apply without it")
        a.showsSuppressionButton=true;a.suppressionButton?.title="Always set Fixed for app looks"
        let r = a.runModal() == .alertFirstButtonReturn
        if r,a.suppressionButton?.state == .on {preferences.set(true,forKey:"alwaysSetFixed")}
        return r
    }
    private func pushUndo() {undoStack.append(UndoState(lighting:lighting,live:live,lookID:currentLookID));if undoStack.count>30 {undoStack.removeFirst()}}
    func undo() {
        guard let u=undoStack.popLast() else {return}
        if let l=u.lighting,l != lighting {setLighting(l)}
        var v=u.live;v.pref=live.pref;v.layout=live.layout
        updateLive{$0=v}
        currentLookID=u.lookID
        show("Undone")
    }
    func show(_ text:String,undo:Bool=false) {
        let t=Toast(text:text,undo:undo && canUndo);toast=t
        DispatchQueue.main.asyncAfter(deadline:.now()+6){[weak self] in if self?.toast?.id==t.id {self?.toast=nil}}
    }

    // MARK: Quick tune (current look)

    /// Brightness: 0–4 for keyboard looks, 0–100 for app looks.
    func setBrightness(_ v:Int) {
        pushUndoIfNew("brightness")
        if liveActive {updateAppLook{$0.liveBrightness=Double(v)/100}} else {edit(.lighting("brightness",min(max(v,0),4)))}
    }
    func setSpeed(_ v:Int) {
        pushUndoIfNew("speed")
        if liveActive {updateAppLook{$0.backgroundSpeed=v}} else {edit(.lighting("speed",v))}
    }
    func setColourSlot(_ i:Int) {pushUndoIfNew("colour");edit(.lighting("colour",i))}
    func setLiveColour(_ c:RGB) {pushUndoIfNew("colour");updateAppLook{$0.color=c;if $0.background=="dark" {$0.background="solid"};$0.multicolour=false}}
    /// Replace a keyboard palette colour, then use it for the current effect.
    func replacePaletteSlot(_ i:Int,with c:RGB) {
        pushUndo()
        var colours=palette;guard colours.indices.contains(i) else{return};colours[i]=c
        edit(.palette(colours));edit(.lighting("colour",i))
        show("Keyboard colour \(i+1) is now \(c.hex.uppercased())")
    }
    func makeSolidAppLook(_ c:RGB) {
        var l=Look(name:"Solid \(c.hex.uppercased())",kind:.app);l.background="solid";l.color=c;l.multicolour=false
        apply(looks.add(l));reloadLooks()
    }
    /// One undo step per kind of tweak, not one per slider tick.
    private var lastTweak:(String,Date)?
    private func pushUndoIfNew(_ kind:String) {
        if let t=lastTweak, t.0 == kind, Date().timeIntervalSince(t.1) < 3 {lastTweak=(kind,Date());return}
        lastTweak=(kind,Date());pushUndo()
    }
    private func updateAppLook(_ change:(inout Look)->Void) {
        var l=currentLook ?? Look.fromLive(live,name:"Live lighting")
        change(&l)
        if looks.look(l.id) != nil {looks.update(l);reloadLooks()}
        updateLive{$0=l.liveSettings($0)}
    }
    /// Pick an onboard effect directly; it keeps that effect's own saved settings.
    func applyEffect(_ e:Int) {
        guard canWrite else {if let led=lighting {var l=Look.capture(led);l.effect=e;l.name=LightingBlock.names[e-1];waitingLook=l};show("\(LightingBlock.names[e-1]) will apply when your F65 wakes.");return}
        pushUndo()
        if liveActive {updateLive{$0.mode = .off}}
        edit(.effect(e));currentLookID=nil
        show("Applied \(LightingBlock.names[e-1])",undo:true)
    }
    @Published var speedCheck=false
    @Published var colourPopover=false
    /// A colour from the command bar that isn't one of the keyboard's 7; the colour chooser asks how to fit it.
    var pendingColour:RGB?

    // MARK: Studio draft
    /// The look being painted in Studio. Always an app look: per-key colours are drawn by the app.
    @Published var draft=Look(name:"My look",kind:.app)
    func studioStart(from look:Look) {
        var d=Look(name:look.name+" copy",kind:.app)
        if look.kind == .app {d=look;d.id=UUID().uuidString;d.name=look.name+" copy"}
        else {
            d.background=Backgrounds.available.contains(look.effect) ? "effect:\(look.effect)":(look.effect==1 ? "solid":"dark")
            d.backgroundSpeed=look.speed;d.multicolour=look.colour==7
            d.color=look.colour<7 ? palette[look.colour]:RGB(r:160,g:0,b:255)
            d.liveBrightness=Look.brightnessLevels[look.brightness]
        }
        d.builtIn=false;d.favourite=false
        draft=d;section="Studio"
    }
    func toggleFavourite(_ id:String) {looks.toggleFavourite(id);reloadLooks()}
    func deleteLook(_ id:String) {looks.remove(id);reloadLooks()}
    func applyNextFavourite() {if let l=looks.nextFavourite(after:currentLookID) {apply(l)}}

    // MARK: Hover preview and "Try on keyboard"

    @Published var previewLook:Look? {didSet {if oldValue?.id != previewLook?.id {previewChanged()} else if oldValue != previewLook {tryOnUpdate()}}}
    @Published var tryOn=false {didSet {tryOnUpdate()}}
    private var previewTimer:Timer?
    /// The look last streamed by Try on. Sending only when it changes keeps state updates from re-sending.
    private var tryOnSent:Look?
    var reduceMotion:Bool {NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    private func previewChanged() {
        previewTimer?.invalidate();previewTimer=nil
        if previewLook != nil {
            let draw={[weak self] in guard let self,let p=self.previewLook else{return};self.liveFrameTarget?.liveFrame(p.previewFrame(time:Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:3600),palette:self.palette))}
            draw()
            if !reduceMotion {let t=Timer(timeInterval:1.0/20,repeats:true){_ in MainActor.assumeIsolated {draw()}};RunLoop.main.add(t,forMode:.common);previewTimer=t}
        } else {liveFrameTarget?.liveFrame(frame)}
        tryOnUpdate()
    }
    /// Streaming a preview needs the cable, or 2.4G while the saved effect is Fixed.
    var canTryOn:Bool {device.online && (device.link == .cable || (device.link == .receiver && lighting?.effect==1))}
    func tryOnUpdate() {
        if tryOn,canTryOn,let p=previewLook,let s=Self.liveApproximation(p,base:live,palette:palette) {if tryOnSent != p {service.update(s);tryOnSent=p}}
        else if tryOnSent != nil {tryOnSent=nil;service.update(live)}
    }
    /// A keyboard look drawn by the app (for previews on the keyboard). Reactive effects can't be drawn.
    static func liveApproximation(_ look:Look,base:F65Kit.Settings,palette:[RGB])->F65Kit.Settings? {
        if look.kind == .app {return look.liveSettings(base)}
        guard look.effect==1 || Backgrounds.available.contains(look.effect) else {return nil}
        var s=base;s.paused=false;s.keyColors=[:]
        let c=look.colour<7 && look.colour<palette.count ? palette[look.colour]:RGB(r:255,g:255,b:255)
        if look.effect==1 {s.mode = .solid;s.color=c} else {s.mode = .effect;s.effect=look.effect;s.effectSpeed=look.speed;s.effectMulticolour=look.colour==7;s.color=c}
        s.brightness=Look.brightnessLevels[min(max(look.brightness,0),4)]
        return s
    }

    // MARK: Per-key live colours
    @Published var liveSelection:Set<String>=[]
    func toggleLiveSelection(_ id:String) {if liveSelection.contains(id) {liveSelection.remove(id)} else {liveSelection.insert(id)}}
    func applyKeyColour(_ c:RGB) {
        guard !liveSelection.isEmpty else{return}
        updateLive{s in for id in liveSelection {s.keyColors[id]=c};if s.mode == .off {s.mode = .dark};s.paused=false}
    }
    func removeKeyColours(_ ids:Set<String>) {updateLive{s in for id in ids {s.keyColors[id]=nil}}}
    func clearKeyColours() {updateLive{$0.keyColors=[:]}}
    func refreshPoints() {points=service.backups.list()}
    func restore(_ url:URL) {
        do {
            let records=try service.backups.load(url)
            let a=NSAlert();a.messageText="Restore \(url.lastPathComponent)?";a.informativeText="This restores \(records.count) saved blocks, including any Fn and connection bindings in the file. A fresh restore point is created first.";a.addButton(withTitle:"Restore");a.addButton(withTitle:"Cancel")
            if a.runModal() == .alertFirstButtonReturn {edit(.restore(records))}
        } catch {device.message=error.localizedDescription}
    }
    func importPoint() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.plainText];panel.canChooseDirectories=false
        if panel.runModal() == .OK,let url=panel.url {do{_ = try service.backups.load(url);if !points.contains(url){points.insert(url,at:0)}}catch{device.message=error.localizedDescription}}
    }
    func remap(_ entry:KeyEntry) {
        guard let id=selected,let slot=PhysicalKey.slots[id],let snapshot=device.snapshot else{return}
        let current=(layer==0 ? snapshot.base:snapshot.fn).entry(slot)
        var allow=false
        if current.protected {
            let a=NSAlert();a.alertStyle = .warning;a.messageText="Replace a protected Fn or connection key?";a.informativeText="This can prevent switching layers, Bluetooth channels or wireless mode. Keep the cable and a restore point available. The original binding is backed up before writing.";a.addButton(withTitle:"Replace binding");a.addButton(withTitle:"Cancel")
            guard a.runModal() == .alertFirstButtonReturn else{return};allow=true
        }
        edit(.remap(slot:slot,layer:UInt8(layer),entry:entry,allowProtected:allow),key:id)
    }
    func restoreKey() {guard let initial,let selected,let slot=PhysicalKey.slots[selected] else{return};remap((layer==0 ? initial.base:initial.fn).entry(slot))}
}
