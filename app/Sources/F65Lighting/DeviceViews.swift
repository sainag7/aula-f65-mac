import SwiftUI
import AppKit
import ServiceManagement
import F65Kit

struct LiveLightingView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            Text("Streamed by this app. Nothing is saved on the keyboard; saved lighting returns after streaming stops.").foregroundStyle(.secondary)
            KeyboardView(model:model).frame(height:340)
            Picker("Live mode",selection:Binding(get:{model.live.mode},set:{v in model.updateLive{$0.mode=v}})){ForEach(Mode.allCases,id:\.self){Text($0.title).tag($0)}}.pickerStyle(.segmented)
            if model.live.mode == .solid {ColorPicker("Solid colour",selection:Binding(get:{model.live.color.color},set:{v in model.updateLive{$0.color=RGB(v)}}),supportsOpacity:false)}
            HStack{Text("Brightness \(Int(model.live.brightness*100))%").frame(width:125,alignment:.leading);Slider(value:Binding(get:{model.live.brightness},set:{v in model.updateLive{$0.brightness=v}}),in:0...1).accessibilityLabel("Live brightness")}
            Toggle("Pause live lighting",isOn:Binding(get:{model.live.paused},set:{v in model.updateLive{$0.paused=v}}))
            Picker("Connection",selection:Binding(get:{model.live.pref},set:{v in model.updateLive{$0.pref=v}})){ForEach(ConnectionPref.allCases,id:\.self){Text($0.title).tag($0)}}.frame(maxWidth:420)
            if model.device.link == .receiver {Label("2.4G live lighting requires the saved Fixed effect. Changing to another effect stops the live display.",systemImage:"info.circle").foregroundStyle(.secondary)
                if model.lighting?.effect != 1 {Button("Save Fixed effect"){model.edit(.effect(1))}.disabled(!model.canWrite)}
            }
            if model.live.mode == .custom {
                HStack{Button("Open layout.json…"){model.onEditLayout?()};Button("Reload layout"){model.onReloadLayout?()}}
                Text(AppPaths.layoutURL.path).font(.caption).textSelection(.enabled)
                let unknown=model.device.snapshot.map{model.live.layout.resolve(KeyMap(bytes:$0.base.bytes)!).unknown} ?? []
                let problems=model.live.layout.problems + (unknown.isEmpty ? []:["Unknown keys: "+unknown.joined(separator:", ")])
                ForEach(problems,id:\.self){Text($0).foregroundStyle(.orange)}
                if problems.isEmpty{Label("Layout loaded",systemImage:"checkmark.circle").foregroundStyle(.secondary)}
            }
        }
    }
}
struct RestorePointsView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            Text("Every save creates a restore point first. Imported CLI backups use the same format.").foregroundStyle(.secondary)
            HStack{Button("Back up now"){model.edit(.backup)}.disabled(!model.canWrite);Button("Import…"){model.importPoint()};Button("Reveal folder"){NSWorkspace.shared.open(model.service.backups.directory)};Spacer();Button("Refresh list"){model.refreshPoints()}}
            if model.points.isEmpty {Label("No restore points yet. Back up the keyboard or import a file from the repository’s backups folder.",systemImage:"clock.arrow.circlepath").padding(24).foregroundStyle(.secondary)}
            ForEach(model.points,id:\.self){url in
                HStack{VStack(alignment:.leading,spacing:4){Text(url.lastPathComponent).font(.system(.callout,design:.monospaced));Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)};Spacer();Button("Reveal"){NSWorkspace.shared.activateFileViewerSelecting([url])};Button("Restore…"){model.restore(url)}.disabled(!model.canWrite)}.padding(14).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:8))
            }
            if model.device.link == .receiver {Text("Use the USB cable for large restores when possible.").foregroundStyle(.secondary)}
        }
    }
}
struct MacrosView:View {
    @ObservedObject var model:AppModel
    @State var showBytes=false
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            Label("Macros are read-only",systemImage:"lock.shield").font(.title2)
            Text("Macro writes are blocked until the format is confirmed.").foregroundStyle(.secondary)
            if let b=model.device.macroBytes {
                Text(b.allSatisfy{$0==0} ? "Macro memory is empty (\(b.count) bytes read).":"\(b.count) bytes read · \(b.filter{$0 != 0}.count) nonzero bytes.")
                DisclosureGroup("Raw macro bytes",isExpanded:$showBytes){Text(hex(b)).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}
            } else {Text("Macro memory could not be read.").foregroundStyle(.secondary)}
            Button("Read again"){model.edit(.refresh)}.disabled(model.busy)
        }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
}
struct DisplaySettingsView:View {
    @ObservedObject var model:AppModel
    @AppStorage("display") var display="3d"
    @AppStorage("flatStyle") var style="lay"
    @AppStorage("camera") var camera="three"
    @AppStorage("colourway") var colourway="white"
    @State var loginStatus=SMAppService.mainApp.status
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            Text("These options change the app preview. They do not change keyboard settings.").foregroundStyle(.secondary)
            KeyboardView(model:model).frame(height:340)
            Picker("Display",selection:$display){Text("3D model").tag("3d");Text("Flat").tag("flat")}.pickerStyle(.segmented)
            if display=="flat" || model.webFailure {Picker("Flat style",selection:$style){Text("Flat lay").tag("lay");Text("Glass").tag("glass");Text("Outline").tag("out")}.pickerStyle(.segmented)}
            if display=="3d" && !model.webFailure {Picker("Camera",selection:$camera){Text("Three-quarter").tag("three");Text("Top").tag("top");Text("Front").tag("front");Text("Close-up").tag("close")}.pickerStyle(.segmented)}
            Picker("Colourway",selection:$colourway){Text("Grey White").tag("white");Text("Black Grey").tag("black")}.pickerStyle(.segmented)
            if model.webFailure {Label("3D is unavailable. Showing the flat keyboard.",systemImage:"info.circle").foregroundStyle(.secondary)}
            Divider()
            HStack{Text("Start at login");Spacer();Text(loginStatus == .enabled ? "On":loginStatus == .requiresApproval ? "Needs approval":"Off").foregroundStyle(.secondary);Button(loginStatus == .enabled ? "Turn off":"Configure…"){model.onLogin?();loginStatus=SMAppService.mainApp.status}}
            Text("Speed direction and battery meaning are unconfirmed. Onboard effect previews are approximations. Reduce Motion follows macOS accessibility settings.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
