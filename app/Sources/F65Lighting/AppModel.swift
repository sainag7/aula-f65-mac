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
    var canWrite:Bool {device.online && device.snapshot != nil && !busy}
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
        guard !busy else{return};pending=true;hover=nil
        service.perform(action){[weak self] result in MainActor.assumeIsolated {
            guard let self else{return};self.pending=false;self.refreshPoints()
            if case .success=result {self.verifiedKey=key}
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
