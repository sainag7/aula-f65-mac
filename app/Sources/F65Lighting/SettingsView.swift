import SwiftUI
import F65Kit

struct SettingsView:View {
    @ObservedObject var model:AppModel
    @AppStorage("speedFaster") var speedFaster=""
    @State var macros=false
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            DisplaySettingsView(model:model)
            Divider()
            VStack(alignment:.leading,spacing:12) {
                Text("Keyboard").font(.headline)
                Picker("Connection",selection:Binding(get:{model.live.pref},set:{v in model.updateLive{$0.pref=v}})){ForEach(ConnectionPref.allCases,id:\.self){Text($0.title).tag($0)}}.frame(maxWidth:420)
                Toggle("Pause app looks (show the saved lighting)",isOn:Binding(get:{model.live.paused},set:{v in model.updateLive{$0.paused=v}}))
                HStack{Text("Speed direction");Text(speedFaster.isEmpty ? "unconfirmed":"higher numbers are \(speedFaster=="higher" ? "faster":"slower") (checked on your keyboard)").foregroundStyle(.secondary);Button(speedFaster.isEmpty ? "Check…":"Check again…"){model.speedCheck=true}}
                HStack{Text("Layout file");Button("Open layout.json…"){model.onEditLayout?()};Button("Reload"){model.onReloadLayout?()}}
                Text("The layout file drives the menu bar's Custom layout mode.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            SideLightsView(model:model)
            Divider()
            DisclosureGroup("Macros (read only)",isExpanded:$macros){MacrosView(model:model).padding(.top,8)}
        }
    }
}
