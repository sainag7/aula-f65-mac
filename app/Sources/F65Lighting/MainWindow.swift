import AppKit
import SwiftUI
import F65Kit

@MainActor final class MainWindow: NSWindowController, NSWindowDelegate {
    let model:AppModel
    init(model:AppModel) {
        self.model=model
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1160,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="F65";window.minSize=NSSize(width:980,height:650);window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self;window.contentView=NSHostingView(rootView:MainView(model:model));window.center();window.setFrameAutosaveName("F65Main")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func open(){NSApp.setActivationPolicy(.regular);showWindow(nil);window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);model.active=true}
    func windowWillClose(_ notification:Notification){model.active=false;model.hover=nil;NSApp.setActivationPolicy(.accessory)}
    func windowDidBecomeKey(_ notification:Notification){model.active=true}
    func windowDidResignKey(_ notification:Notification){model.active=false;model.hover=nil}
    func windowDidChangeOcclusionState(_ notification:Notification){model.active=window?.isKeyWindow==true && window?.occlusionState.contains(.visible)==true}
}
struct MainView:View {
    @ObservedObject var model:AppModel
    @Environment(\.accessibilityReduceMotion) var reduced
    let sections=[("Lighting","sun.max"),("Live lighting","waveform.path"),("Keys","keyboard"),("Macros","lock"),("Restore points","clock.arrow.circlepath"),("Settings","gearshape")]
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Text("AULA F65").font(.headline);Spacer()
                if model.service.isMock {Label("Mock keyboard",systemImage:"testtube.2").foregroundStyle(.orange)}
                Label(model.device.online ? "Online":"Offline",systemImage:model.device.online ? "circle.fill":"circle").foregroundStyle(model.device.online ? .green:.secondary)
                Text(model.device.link == .cable ? "Cable 258A:010C":model.device.link == .receiver ? "2.4G 3554:FA09":"Not connected")
                Text(model.device.battery.map{"Battery ~\($0)% · unconfirmed"} ?? "Battery unconfirmed").foregroundStyle(.secondary)
                Button {model.edit(.refresh)} label:{Image(systemName:"arrow.clockwise")}.help("Read keyboard settings").disabled(model.busy)
            }.font(.caption).padding(16)
            Divider()
            HStack(spacing:0) {
                VStack(alignment:.leading,spacing:5) {
                    Text("KEYBOARD").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom,8)
                    ForEach(sections,id:\.0) {section,icon in
                        Button {model.section=section;model.hover=nil} label:{Label(section,systemImage:icon).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(model.section==section ? Color.accentColor.opacity(0.13):.clear,in:RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain)
                    }
                    Spacer();Text("F65 Lighting\nSettings stay on your keyboard.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width:180).background(.quaternary.opacity(0.35))
                Divider()
                ScrollView {
                    VStack(alignment:.leading,spacing:22) {
                        HStack{Text(model.section).font(.largeTitle.weight(.semibold));Spacer()}
                        if model.device.permissionDenied {
                            Label("Allow Input Monitoring to access the F65.",systemImage:"hand.raised").foregroundStyle(.orange)
                            Button("Open System Settings"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)}
                        }
                        sectionContent
                    }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            Divider()
            VStack(alignment:.leading,spacing:6) {
                if model.device.total>0 {
                    HStack(spacing:2){ForEach(0..<model.device.total,id:\.self){i in RoundedRectangle(cornerRadius:2).fill(i<model.device.progress ? (model.device.resend ? Color.orange:Color.accentColor):Color.secondary.opacity(0.2)).frame(height:4)}}
                        .animation(reduced ? nil:.easeOut(duration:0.12),value:model.device.progress)
                        .accessibilityLabel("\(model.device.progress) of \(model.device.total) packets acknowledged")
                }
                HStack{if model.busy{ProgressView().controlSize(.small)};Text(model.device.message).font(.caption).textSelection(.enabled);Spacer()
                    if let url=model.device.recovery {Button("Restore backup"){model.restore(url)}.disabled(model.busy)}
                }
            }.padding(12)
        }.frame(minWidth:980,minHeight:650)
    }
    @ViewBuilder var sectionContent:some View {
        if model.section=="Lighting" {LightingView(model:model)}
        else {KeyboardView(model:model).frame(height:340)}
    }
}
