import SwiftUI
import AppKit
import F65Kit

/// Click a key, then search for what it should send (or press a key to copy it).
struct KeysView:View {
    @ObservedObject var model:AppModel
    @State var query=""
    @State var mods=Set<Int>()
    @State var capturing=false
    @State var monitor:Any?
    @Environment(\.accessibilityReduceMotion) var reduced
    struct Target:Hashable {let name:String;let label:String;let group:String}
    static let targets:[Target]={
        var t:[Target]=[]
        t+="abcdefghijklmnopqrstuvwxyz".map{Target(name:String($0),label:String($0).uppercased(),group:"Letter")}
        t+=(0...9).map{Target(name:"\($0)",label:"\($0)",group:"Digit")}
        t+=(1...12).map{Target(name:"f\($0)",label:"F\($0)",group:"Function key")}
        t+=[("esc","Esc"),("enter","Enter"),("backspace","Backspace"),("tab","Tab"),("space","Space"),("caps","Caps Lock"),("delete","Delete"),("insert","Insert"),("home","Home"),("end","End"),("pgup","Page Up"),("pgdn","Page Down"),("printscreen","Print Screen"),("scrolllock","Scroll Lock"),("pause","Pause"),("menu","Menu"),("up","Up arrow"),("down","Down arrow"),("left","Left arrow"),("right","Right arrow"),("-","-"),("=","="),("[","["),("]","]"),("\\","\\"),(";",";"),("'","'"),("`","`"),(",",","),(".","."),("/","/")].map{Target(name:$0.0,label:$0.1,group:"Key")}
        t+=[("lctrl","Left Control"),("rctrl","Right Control"),("lshift","Left Shift"),("rshift","Right Shift"),("lalt","Left Option ⌥"),("ralt","Right Option ⌥"),("lcmd","Left Command ⌘"),("rcmd","Right Command ⌘")].map{Target(name:$0.0,label:$0.1,group:"Modifier")}
        t+=[("mute","Mute"),("volup","Volume +"),("voldown","Volume −"),("play","Play/Pause"),("next","Next track"),("prev","Previous track"),("stop","Stop"),("brightup","Brightness +"),("brightdown","Brightness −")].map{Target(name:$0.0,label:$0.1,group:"Media")}
        t.append(Target(name:"none",label:"Disable this key",group:"Other"))
        return t
    }()
    static let aliases=["⌘":"command","cmd":"command","opt":"option","alt":"option","ctrl":"control","sound":"volume","music":"play","escape":"esc","return":"enter","del":"delete","off":"disable","vol":"volume"]
    var results:[Target] {
        var q=query.lowercased().trimmingCharacters(in:.whitespaces);if let a=Self.aliases[q] {q=a}
        guard !q.isEmpty else {return Self.targets}
        return Self.targets.filter{$0.label.lowercased().contains(q) || $0.name==q || $0.group.lowercased().contains(q)}.sorted{a,b in (a.label.lowercased()==q ? 0:1)<(b.label.lowercased()==q ? 0:1)}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16){
            HStack{
                Text("Click a key on the keyboard, then search for what it should send.").foregroundStyle(.secondary)
                Spacer()
                Picker("Key layer",selection:$model.layer){Text("Base").tag(0);Text("Fn layer").tag(1)}.pickerStyle(.segmented).frame(width:220)
            }
            HStack(alignment:.top,spacing:16) {
                VStack(alignment:.leading,spacing:10) {
                    KeyboardView(model:model).frame(height:330).animation(reduced ? nil:.easeOut(duration:model.layer==1 ? 0.22:0.15),value:model.layer)
                    Picker("Physical key",selection:Binding(get:{model.selected ?? "esc"},set:{model.selected=$0})){ForEach(PhysicalKey.ids,id:\.self){Text(KeyLabel.long($0)).tag($0)}}.frame(width:260)
                    changedKeys
                }
                inspector.frame(width:330)
            }
        }
        .onDisappear{stopCapture()}
    }
    @ViewBuilder var inspector:some View {
        if let snapshot=model.device.snapshot,let id=model.selected,let slot=PhysicalKey.slots[id] {
            let entry=(model.layer==0 ? snapshot.base:snapshot.fn).entry(slot)
            VStack(alignment:.leading,spacing:12){
                HStack{Text(KeyLabel.long(id)).font(.title2.weight(.semibold));Spacer();Text("slot \(slot) · \(model.layer==0 ? "Base":"Fn")").font(.caption.monospaced()).foregroundStyle(.secondary)}
                Text("Sends now: \(entry.description)").font(.callout)
                if entry.protected {Label("Protected Fn or connection binding. Changing it asks for confirmation and backs up the original first.",systemImage:"lock.shield").foregroundStyle(.orange).font(.callout)}
                HStack{Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField(capturing ? "Press a key on your keyboard…":"Search: mute, ⌘, F5, disable…",text:$query).textFieldStyle(.plain)}
                    .padding(7).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).strokeBorder(Color.secondary.opacity(0.3)))
                Button {capturing ? stopCapture():startCapture()} label:{Label(capturing ? "Listening… press a key":"Press a key to copy it",systemImage:"keyboard")}.tint(capturing ? .accentColor:nil).buttonStyle(.bordered)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:1) {
                        ForEach(results,id:\.self) {t in
                            Button {send(t)} label:{HStack{Text(t.label);Spacer();Text(t.group).font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,8).padding(.vertical,5).contentShape(Rectangle())}
                                .buttonStyle(.plain).background(t==results.first && !query.isEmpty ? Color.accentColor.opacity(0.13):.clear,in:RoundedRectangle(cornerRadius:6))
                        }
                    }
                }.frame(height:190)
                if !query.isEmpty,let t=results.first {Button("Send \(t.label)"){send(t)}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)}
                HStack{Text("With").font(.caption);ForEach(Array(["⌃","⇧","⌥","⌘"].enumerated()),id:\.offset){i,name in Toggle(name,isOn:Binding(get:{mods.contains(i)},set:{if $0{mods.insert(i)}else{mods.remove(i)}})).toggleStyle(.checkbox)}}.help("Add modifiers to an ordinary key")
                Button("Restore this key"){model.restoreKey()}.help("Back to the binding loaded when this app session connected")
                Text("Saving writes the \(model.layer==0 ? "Base":"Fn") layer.\(model.device.link == .receiver ? " The USB cable is recommended for key changes.":"")").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12)).disabled(!model.canWrite)
        } else {Text("Connect and wake the keyboard to load both layers.").foregroundStyle(.secondary)}
    }
    /// Base-layer keys that differ from the F65's default layout, each with a one-click reset.
    @ViewBuilder var changedKeys:some View {
        if let s=model.device.snapshot,model.layer==0 {
            let changed=PhysicalKey.ids.filter{s.base.entry(PhysicalKey.slots[$0]!).bytes != KeyMap.fallback.entry(PhysicalKey.slots[$0]!)}
            VStack(alignment:.leading,spacing:6) {
                Text("Changed keys").font(.headline)
                if changed.isEmpty {Text("All keys send their default.").font(.callout).foregroundStyle(.secondary)}
                ForEach(changed,id:\.self) {id in
                    let e=s.base.entry(PhysicalKey.slots[id]!)
                    HStack{Text(KeyLabel.long(id)).fontWeight(.semibold);Text("→ \(e.description)").foregroundStyle(.secondary);Spacer()
                        Button{model.selected=id;model.remap(KeyEntry(KeyMap.fallback.entry(PhysicalKey.slots[id]!)))} label:{Label("Reset",systemImage:"arrow.counterclockwise")}.controlSize(.small).disabled(!model.canWrite)}
                }
            }.padding(12).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
        }
    }
    func send(_ t:Target) {
        guard var bytes=KeyEntry.named(t.name)?.bytes else {return}
        if bytes[0]==0,bytes[3] != 0 {for m in mods {bytes[1] |= UInt8(1<<m)}}
        model.remap(KeyEntry(bytes));query=""
    }
    static let captureNames:[UInt16:String]=[0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",32:"u",33:"[",34:"i",35:"p",36:"enter",37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",43:",",44:"/",45:"n",46:"m",47:".",48:"tab",49:"space",50:"`",51:"backspace",53:"esc",96:"f5",97:"f6",98:"f7",99:"f3",100:"f8",101:"f9",103:"f11",109:"f10",111:"f12",114:"insert",115:"home",116:"pgup",117:"delete",118:"f4",119:"end",120:"f2",121:"pgdn",122:"f1",123:"left",124:"right",125:"down",126:"up"]
    func startCapture() {
        capturing=true
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) {e in
            if let name=Self.captureNames[e.keyCode],let t=Self.targets.first(where:{$0.name==name}) {query=t.label;stopCapture();return nil}
            return e
        }
    }
    func stopCapture() {capturing=false;if let m=monitor {NSEvent.removeMonitor(m)};monitor=nil}
}
