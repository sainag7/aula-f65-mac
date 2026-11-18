import SwiftUI
import AppKit
import ServiceManagement
import F65Kit

struct LiveLightingView:View {
    @ObservedObject var model:AppModel
    @State var keyColour=Color.red
    /// Background choices: "off", "dark", "solid", "wave", "custom" or "effect:<n>".
    var background:Binding<String> {Binding(get:{model.live.mode == .effect ? "effect:\(model.live.effect)":model.live.mode.rawValue},set:{v in
        model.updateLive{s in
            if v.hasPrefix("effect:"),let e=Int(v.dropFirst(7)) {s.mode = .effect;s.effect=e} else if let m=Mode(rawValue:v) {s.mode=m}
            if s.mode == .custom {model.onReloadLayout?()}
        }
    })}
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            Text("Streamed by this app. Nothing is saved on the keyboard; saved lighting returns after streaming stops.").foregroundStyle(.secondary)
            KeyboardView(model:model).frame(height:340)
            HStack(alignment:.top,spacing:24){
                VStack(alignment:.leading,spacing:14){backgroundControls}.frame(maxWidth:.infinity,alignment:.leading)
                keyColourPanel.frame(width:330)
            }
            HStack{Text("Brightness \(Int(model.live.brightness*100))%").frame(width:125,alignment:.leading);Slider(value:Binding(get:{model.live.brightness},set:{v in model.updateLive{$0.brightness=v}}),in:0...1).accessibilityLabel("Live brightness")}
            Toggle("Pause live lighting",isOn:Binding(get:{model.live.paused},set:{v in model.updateLive{$0.paused=v}}))
            Picker("Connection",selection:Binding(get:{model.live.pref},set:{v in model.updateLive{$0.pref=v}})){ForEach(ConnectionPref.allCases,id:\.self){Text($0.title).tag($0)}}.frame(maxWidth:420)
            if model.device.link == .receiver {Label("2.4G live lighting requires the saved Fixed effect. Changing to another effect stops the live display.",systemImage:"info.circle").foregroundStyle(.secondary)
                if model.lighting?.effect != 1 {Button("Save Fixed effect"){model.edit(.effect(1))}.disabled(!model.canWrite)}
            }
            // Each onboard save restarts the keyboard's own effect, which fades in before it accepts live colours
            // again. At brightness 0 that fade-in stays dark; live colours are not dimmed by it (tested on the F65).
            if model.live.mode != .off,let led=model.lighting,(1...18).contains(led.effect),led.brightness(led.effect)>0 {
                VStack(alignment:.leading,spacing:6) {
                    Label("After every onboard lighting change, the keyboard fades its own \(led.name) effect back in before live colours return. Set its brightness to 0 to keep that dark. Live colours stay at full brightness, but the keys are dark when this app isn't running.",systemImage:"lightbulb").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Button("Set \(led.name) brightness to 0"){model.edit(.lighting("brightness",0))}.disabled(!model.canWrite)
                }
            }
        }
    }

    @ViewBuilder var backgroundControls:some View {
        Text("Rest of keyboard").font(.headline)
        Picker("Rest of keyboard",selection:background){
            Text("Off (show saved lighting)").tag("off")
            Text("Dark").tag("dark")
            Text("Solid colour").tag("solid")
            Text("Rainbow wave").tag("wave")
            Divider()
            ForEach(Backgrounds.available,id:\.self){e in Text(Backgrounds.name(e)).tag("effect:\(e)")}
            Divider()
            Text("Custom layout file").tag("custom")
        }.labelsHidden().frame(maxWidth:280)
        if model.live.mode == .solid {colourPicker("Colour")}
        if model.live.mode == .effect {
            if !Backgrounds.alwaysMulticolour.contains(model.live.effect) {
                Toggle("Multicolour",isOn:Binding(get:{model.live.effectMulticolour},set:{v in model.updateLive{$0.effectMulticolour=v}}))
                if !model.live.effectMulticolour {colourPicker("Effect colour")}
            }
            VStack(alignment:.leading){Text("Speed").font(.subheadline)
                Picker("Speed",selection:Binding(get:{model.live.effectSpeed},set:{v in model.updateLive{$0.effectSpeed=v}})){ForEach(0...4,id:\.self){Text("\($0)").tag($0)}}.pickerStyle(.segmented).labelsHidden().frame(width:220)}
            Text("Drawn by the app to match the onboard effect. Ripples, Reaction and other keypress effects aren't available yet.").font(.caption).foregroundStyle(.secondary)
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

    func colourPicker(_ label:String)->some View {
        ColorPicker(label,selection:Binding(get:{model.live.color.color},set:{v in model.updateLive{$0.color=RGB(v)}}),supportsOpacity:false)
    }

    var keyColourPanel:some View {
        VStack(alignment:.leading,spacing:12){
            Text("Key colours").font(.headline)
            Text("Click keys on the keyboard to select them; click again to deselect. Their colour stays on top of the rest of the keyboard.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text(model.liveSelection.isEmpty ? "No keys selected":"Selected: "+model.liveSelection.sorted().map(Self.label).joined(separator:", ")).font(.callout).lineLimit(2)
            HStack{
                ColorPicker("Colour",selection:$keyColour,supportsOpacity:false).labelsHidden()
                Button("Apply to selected"){model.applyKeyColour(RGB(keyColour))}.buttonStyle(.borderedProminent).disabled(model.liveSelection.isEmpty)
            }
            HStack{
                Button("Select WASD"){model.liveSelection=["w","a","s","d"]}
                Button("Arrows"){model.liveSelection=["up","down","left","right"]}
                Button("Select none"){model.liveSelection=[]}.disabled(model.liveSelection.isEmpty)
            }.controlSize(.small)
            HStack{
                Button("Remove colour"){model.removeKeyColours(model.liveSelection)}.disabled(model.liveSelection.allSatisfy{model.live.keyColors[$0]==nil})
                Button("Clear all"){model.clearKeyColours()}.disabled(model.live.keyColors.isEmpty)
            }.controlSize(.small)
            if !model.live.keyColors.isEmpty {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:86),spacing:6)],alignment:.leading,spacing:6){
                    ForEach(model.live.keyColors.keys.sorted(),id:\.self){id in
                        HStack(spacing:5){
                            Circle().fill(model.live.keyColors[id]!.color).frame(width:12,height:12).overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                            Text(Self.label(id)).font(.caption).lineLimit(1)
                            Button{model.removeKeyColours([id])} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove colour from \(Self.label(id))")
                        }.padding(.horizontal,7).padding(.vertical,4).background(Color(nsColor:.controlBackgroundColor),in:Capsule())
                        .onTapGesture{model.liveSelection.insert(id)}
                    }
                }
            }
        }.padding(16).background(Color(nsColor:.controlBackgroundColor).opacity(0.6),in:RoundedRectangle(cornerRadius:12))
    }

    static func label(_ id:String)->String {
        let names=["d1":"1","d2":"2","d3":"3","d4":"4","d5":"5","d6":"6","d7":"7","d8":"8","d9":"9","d0":"0","minus":"-","equal":"=","bksp":"Backspace","lbr":"[","rbr":"]","bslash":"\\","semi":";","quote":"'","comma":",","period":".","slash":"/","lshift":"L Shift","rshift":"R Shift","lctrl":"L Ctrl","rctrl":"R Ctrl","lwin":"Win","lalt":"Alt","pgup":"PgUp","pgdn":"PgDn","up":"↑","down":"↓","left":"←","right":"→","caps":"Caps","esc":"Esc","del":"Del","enter":"Enter","space":"Space","tab":"Tab","end":"End","fn":"Fn"]
        return names[id] ?? id.uppercased()
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
