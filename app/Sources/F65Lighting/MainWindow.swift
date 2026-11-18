import AppKit
import SwiftUI
import F65Kit

@MainActor final class MainWindow: NSWindowController, NSWindowDelegate {
    let model:AppModel
    init(model:AppModel) {
        self.model=model
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="F65";window.appearance=NSAppearance(named:.darkAqua);window.backgroundColor=Theme.nsBackground;window.titlebarAppearsTransparent=true;window.minSize=NSSize(width:1000,height:680);window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self;window.contentView=NSHostingView(rootView:MainView(model:model).defaultAppStorage(model.preferences));window.center();window.setFrameAutosaveName("F65Main")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func open(){NSApp.setActivationPolicy(.regular);showWindow(nil);window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);model.active=true}
    func windowWillClose(_ notification:Notification){model.active=false;model.hover=nil;model.previewLook=nil;NSApp.setActivationPolicy(.accessory)}
    func windowDidBecomeKey(_ notification:Notification){model.active=true}
    func windowDidResignKey(_ notification:Notification){model.active=false;model.hover=nil;model.previewLook=nil}
    func windowDidChangeOcclusionState(_ notification:Notification){model.active=window?.isKeyWindow==true && window?.occlusionState.contains(.visible)==true}
}
// Motion token: 2.4 s ease-in-out outline pulse while 07 reports the keyboard asleep. Static with Reduce Motion.
struct WakePrompt:View {
    @Environment(\.accessibilityReduceMotion) var reduced
    @State var pulse=false
    var waiting:String?
    var body:some View {
        Label(waiting.map{"Press any key on the F65 to wake it. \($0) applies as soon as it answers."} ?? "Press any key on the F65 to wake it. You can keep choosing looks; they apply when it answers.",systemImage:"keyboard.badge.ellipsis")
            .padding(14).frame(maxWidth:.infinity,alignment:.leading)
            .background(Theme.accent.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Theme.accent.opacity(reduced ? 0.5:(pulse ? 0.85:0.15)),lineWidth:2))
            .onAppear{guard !reduced else{return};withAnimation(.easeInOut(duration:1.2).repeatForever(autoreverses:true)){pulse=true}}
            .accessibilityAddTraits(.updatesFrequently)
    }
}
struct MainView:View {
    @ObservedObject var model:AppModel
    @Environment(\.accessibilityReduceMotion) var reduced
    let sections=[("Looks","square.grid.2x2"),("Studio","paintbrush"),("Keys","keyboard"),("History","clock.arrow.circlepath"),("Settings","gearshape")]
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Text("AULA F65").font(.headline)
                Button {model.commandBar=true} label:{HStack{Image(systemName:"magnifyingglass");Text("Type a command or a look…");Spacer();Text("⌘K").foregroundStyle(.secondary)}.frame(width:300)}
                    .buttonStyle(.bordered).keyboardShortcut("k",modifiers:.command).help("Command bar: try “wasd red”, “dim 50” or “storm”")
                Spacer()
                if model.service.isMock {Label("Mock keyboard",systemImage:"testtube.2").foregroundStyle(.orange)}
                Label(model.device.online ? "Online":"Offline",systemImage:model.device.online ? "circle.fill":"circle").foregroundStyle(model.device.online ? .green:.secondary)
                Text(model.device.link == .cable ? "Cable 258A:010C":model.device.link == .receiver ? "2.4G 3554:FA09":"Not connected")
                if model.device.link == .receiver {Text(model.device.battery.map{"Battery ~\($0)% · unconfirmed"} ?? "Battery unconfirmed").foregroundStyle(.secondary)}
                Button {model.edit(.refresh)} label:{Image(systemName:"arrow.clockwise")}.help("Read keyboard settings").disabled(model.busy)
            }.font(.caption).padding(.horizontal,16).padding(.vertical,10)
            Divider()
            HStack(spacing:0) {
                VStack(alignment:.leading,spacing:5) {
                    ForEach(sections,id:\.0) {section,icon in
                        Button {model.section=section;model.hover=nil;model.previewLook=nil} label:{Label(section,systemImage:icon).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(model.section==section ? Theme.accent.opacity(0.13):.clear,in:RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain)
                    }
                    Spacer();Text("Looks marked On keyboard keep working with this app closed.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width:180).background(Theme.sidebar)
                Divider()
                ZStack(alignment:.bottom) {
                    ScrollView {
                        VStack(alignment:.leading,spacing:18) {
                            HStack{Text(model.section).font(.largeTitle.weight(.semibold));Spacer()}
                            if model.device.link == .receiver && !model.device.online && !model.device.permissionDenied {WakePrompt(waiting:model.waitingLook?.name)}
                            if model.device.permissionDenied {
                                Label("Allow Input Monitoring to access the F65.",systemImage:"hand.raised").foregroundStyle(.orange)
                                Button("Open System Settings"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)}
                            }
                            sectionContent
                        }.padding(24).padding(.bottom,40).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    ToastView(model:model).padding(.bottom,14)
                }.animation(reduced ? nil:.easeOut(duration:0.2),value:model.toast)
            }
            Divider()
            VStack(alignment:.leading,spacing:6) {
                if model.device.total>0 {
                    HStack(spacing:2){ForEach(0..<model.device.total,id:\.self){i in RoundedRectangle(cornerRadius:2).fill(i<model.device.progress ? (model.device.resend ? Color.orange:Theme.accent):Color.secondary.opacity(0.2)).frame(height:4)}}
                        .animation(reduced ? nil:.easeOut(duration:0.12),value:model.device.progress)
                        .accessibilityLabel("\(model.device.progress) of \(model.device.total) packets acknowledged")
                }
                HStack{if model.busy{ProgressView().controlSize(.small)};Text(model.device.message).font(.caption).textSelection(.enabled);Spacer()
                    if model.liveActive {Text(model.device.link == .receiver && model.lighting?.effect != 1 ? "App look paused: over 2.4G the saved effect must be Fixed":"Streaming \(model.currentLook?.name ?? "live lighting") · 20 fps").font(.caption).foregroundStyle(.secondary)}
                    if let url=model.device.recovery {Button("Restore backup"){model.restore(url)}.disabled(model.busy)}
                }
            }.padding(12)
        }
        .frame(minWidth:1000,minHeight:680)
        .background(Theme.bg).tint(Theme.accent).preferredColorScheme(.dark)
        .background(Button(""){model.undo()}.keyboardShortcut("z",modifiers:.command).opacity(0).frame(width:0,height:0).accessibilityHidden(true))
        .sheet(isPresented:$model.commandBar){CommandBar(model:model)}
        .sheet(isPresented:$model.speedCheck){SpeedCheck(model:model)}
    }
    @ViewBuilder var sectionContent:some View {
        if model.section=="Looks" {LooksView(model:model)}
        else if model.section=="Studio" {StudioView(model:model)}
        else if model.section=="Keys" {KeysView(model:model)}
        else if model.section=="History" {HistoryView(model:model)}
        else {SettingsView(model:model)}
    }
}
