import AppKit
import SwiftUI
import F65Kit

@MainActor final class AppModel: ObservableObject {
    let service:DeviceService
    var preferences:UserDefaults {service.isMock ? UserDefaults(suiteName:"local.f65.lighting.mock")! : .standard}
    @Published var device=DeviceState()
    @Published var live=F65Kit.Settings()
    @Published var pending=false
    @Published var section="Lighting"
    @Published var hover:Int?
    @Published var selected:String?="esc"
    @Published var layer=0
    @Published var frame:[RGB]?
    @Published var points:[URL]=[]
    @Published var initial:Snapshot?
    @Published var verifiedKey:String?
    @Published var webFailure=false
    @Published var active=true
    var onLive:((F65Kit.Settings)->Void)?
    var onLogin:(()->Void)?
    var onEditLayout:(()->Void)?
    var onReloadLayout:(()->Void)?
    var busy:Bool {pending || device.busy}
    // Controls stay enabled while a save runs; further clicks are queued instead of greying the window.
    var canWrite:Bool {device.online && device.snapshot != nil}
    /// Lighting shown in the UI: the user's latest choice right away, before the keyboard confirms it.
    @Published var optimistic:LightingBlock?
    var lighting:LightingBlock? {optimistic ?? device.snapshot?.lighting}
    private var queue:[(DeviceEdit,String?)]=[]
    init(service:DeviceService) {
        self.service=service
        service.onState={[weak self] state in MainActor.assumeIsolated {
            self?.device=state
            if self?.initial==nil {self?.initial=state.snapshot}
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
        if pending {
            // Several quick lighting clicks collapse into one save of the latest value.
            if Self.isLighting(action),let desired=optimistic {queue.removeAll{Self.isLighting($0.0)};queue.append((.lightingBlock(desired),key))}
            else {queue.append((action,key))}
            return
        }
        run(action,key:key)
    }
    private static func isLighting(_ e:DeviceEdit)->Bool {switch e {case .effect,.lighting,.lightingBlock:return true;default:return false}}
    private func run(_ action:DeviceEdit,key:String?) {
        pending=true
        service.perform(action){[weak self] result in MainActor.assumeIsolated {
            guard let self else{return};self.refreshPoints()
            if case .success=result {self.verifiedKey=key}
            if !self.queue.isEmpty {let next=self.queue.removeFirst();self.run(next.0,key:next.1);return}
            self.pending=false;self.optimistic=nil
        }}
    }
    func updateLive(_ change:(inout F65Kit.Settings)->Void) {var value=live;change(&value);live=value;onLive?(value)}
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
