import SwiftUI
import F65Kit

struct KeysView:View {
    @ObservedObject var model:AppModel
    @State var target="a"
    @State var mods=Set<Int>()
    @Environment(\.accessibilityReduceMotion) var reduced
    let names=(Array("abcdefghijklmnopqrstuvwxyz").map(String.init)+Array(0...9).map(String.init)+(1...12).map{"f\($0)"}+["esc","tab","caps","enter","space","backspace","delete","home","end","pgup","pgdn","left","right","up","down","-","=","[","]","\\",";","'",",",".","/","lctrl","lshift","lalt","lcmd","rctrl","rshift","ralt","rcmd","mute","volup","voldown","play","next","prev","stop","brightup","brightdown"])
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            Picker("Key layer",selection:$model.layer){Text("Base").tag(0);Text("Fn layer").tag(1)}.pickerStyle(.segmented).frame(width:240)
            KeyboardView(model:model).frame(height:340).animation(reduced ? nil:.easeOut(duration:model.layer==1 ? 0.22:0.15),value:model.layer)
            Text("Click a key to inspect it. Fn bindings are outlined; empty bindings dim. Physical positions stay the same after remapping.").font(.callout).foregroundStyle(.secondary)
            // Native picker is also a keyboard/VoiceOver alternative to the 3D canvas.
            Picker("Physical key",selection:Binding(get:{model.selected ?? "esc"},set:{model.selected=$0})){ForEach(PhysicalKey.ids,id:\.self){Text($0.uppercased()).tag($0)}}.frame(width:300)
            if let snapshot=model.device.snapshot,let id=model.selected,let slot=PhysicalKey.slots[id] {
                let entry=(model.layer==0 ? snapshot.base:snapshot.fn).entry(slot)
                VStack(alignment:.leading,spacing:14){
                    HStack{Text(id.uppercased()).font(.title2.weight(.semibold));Text("Slot \(slot) · \(model.layer==0 ? "Base":"Fn")").foregroundStyle(.secondary)}
                    Text(entry.description).font(.headline);Text(entry.hex).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                    if entry.protected {Label("Protected Fn / connection binding. Replacing it requires confirmation.",systemImage:"lock.shield").foregroundStyle(.orange)}
                    HStack{
                        Picker("Send",selection:$target){ForEach(names,id:\.self){name in Text(label(name)).tag(name)}}.frame(width:290)
                        Button("Remap key"){if var bytes=KeyEntry.named(target)?.bytes {if bytes[0]==0 {for m in mods{bytes[1] |= UInt8(1<<m)}};model.remap(KeyEntry(bytes))}}.buttonStyle(.borderedProminent)
                        Button("Disable key"){model.remap(KeyEntry([0,0,0,0]))}
                        Button("Restore this key"){model.restoreKey()}.help("Restore the binding loaded when this app session connected")
                    }
                    if KeyEntry.named(target)?.bytes[0]==0 {
                        HStack{Text("Modifiers");ForEach(Array(["⌃ Ctrl","⇧ Shift","⌥ Option","⌘ Cmd"].enumerated()),id:\.offset){i,name in Toggle(name,isOn:Binding(get:{mods.contains(i)},set:{if $0{mods.insert(i)}else{mods.remove(i)}})).toggleStyle(.checkbox)}}
                    }
                    Text("Restore this key uses the first complete snapshot from this app session. Older bindings are available in Restore points.").font(.caption).foregroundStyle(.secondary)
                    if model.device.link == .receiver {Text("For key remaps, the USB cable is recommended.").font(.caption).foregroundStyle(.secondary)}
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12)).disabled(!model.canWrite)
            } else {Text("Connect and wake the keyboard to load both layers.").foregroundStyle(.secondary)}
        }
    }
    func label(_ name:String)->String {switch name {case "lcmd":return "Left ⌘ Cmd";case "rcmd":return "Right ⌘ Cmd";case "lalt":return "Left ⌥ Option";case "ralt":return "Right ⌥ Option";default:return name.capitalized}}
}
