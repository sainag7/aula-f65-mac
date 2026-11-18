import SwiftUI
import AppKit
import F65Kit

/// ⌘K: type what you want ("wasd red", "dim 50", "storm", "undo").
struct CommandBar:View {
    @ObservedObject var model:AppModel
    @State var text=""
    @State var selected=0
    @FocusState var focused:Bool
    var suggestions:[CommandSuggestion] {CommandParser.suggestions(text,looks:model.lookList,keyboardLook:!model.liveActive,palette:model.palette)}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command or a look",text:$text).textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit{run(selected)}.onChange(of:text){_ in selected=0}
                    .onMoveCommand{d in let n=suggestions.count;guard n>0 else{return};if d == .down {selected=(selected+1)%n};if d == .up {selected=(selected+n-1)%n}}
            }.padding(14)
            Divider()
            let list=suggestions
            if list.isEmpty {
                VStack(alignment:.leading,spacing:6) {
                    Text(text.isEmpty ? "Try:":"No command for “\(text)”. Try:").font(.callout).foregroundStyle(.secondary)
                    ForEach(["wasd red","dim 50","storm","arrows cyan","off","undo"],id:\.self){ex in Button(ex){text=ex}.buttonStyle(.link)}
                }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
            } else {
                VStack(spacing:2) {
                    ForEach(Array(list.enumerated()),id:\.offset) {i,s in
                        Button {run(i)} label:{
                            HStack(spacing:10) {
                                Image(systemName:s.symbol).frame(width:24,height:24).background(Color.primary.opacity(0.07),in:RoundedRectangle(cornerRadius:6)).foregroundStyle(Theme.accent)
                                VStack(alignment:.leading,spacing:1){Text(s.title);Text(s.detail).font(.caption).foregroundStyle(.secondary)}
                                Spacer();if i==selected {Text("↵").foregroundStyle(.secondary)}
                            }.padding(8).frame(maxWidth:.infinity,alignment:.leading).background(i==selected ? Theme.accent.opacity(0.15):.clear,in:RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(6)
            }
            Divider()
            HStack(spacing:14){Text("↑↓ choose");Text("↵ apply");Text("esc close");Spacer();Button("Close"){model.commandBar=false}.keyboardShortcut(.cancelAction)}.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(width:560).onAppear{focused=true}
    }
    func run(_ i:Int) {
        let list=suggestions;guard list.indices.contains(i) else {return}
        model.commandBar=false
        DispatchQueue.main.async {model.run(list[i].command)}
    }
}

extension AppModel {
    func run(_ c:LookCommand) {
        switch c {
        case .paint(let ids,let colour):
            // Paint on top of what's showing, kept in one reusable "Quick paint" look.
            var l=currentLook.map{$0.kind == .app ? $0:Self.appVersion(of:$0,palette:palette)} ?? Look(name:"Quick paint",kind:.app)
            for id in ids {l.keyColors[id]=colour}
            l.name="Quick paint";l.builtIn=false
            if let q=looks.look("quick") {l.id=q.id;l.favourite=q.favourite;looks.update(l)} else {l.id="quick";l.favourite=false;looks.add(l)}
            reloadLooks()
            if let stored=looks.look("quick") {apply(stored)}
        case .brightness(let pct): setBrightness(liveActive ? pct:Int((Double(pct)/25).rounded()))
        case .lightsOff: setBrightness(0)
        case .undo: undo()
        case .apply(let id): if let l=looks.look(id) {apply(l)}
        case .effect(let e): applyEffect(e)
        case .colour(let rgb):
            if liveActive {setLiveColour(rgb)}
            else if let i=palette.firstIndex(of:rgb) {setColourSlot(i)}
            else {pendingColour=rgb;section="Looks";colourPopover=true}
        }
    }
    /// A keyboard look drawn by the app, so keys can be painted on top of it.
    static func appVersion(of look:Look,palette:[RGB])->Look {
        var d=Look(name:look.name,kind:.app)
        d.background=Backgrounds.available.contains(look.effect) ? "effect:\(look.effect)":(look.effect==1 ? "solid":"dark")
        d.backgroundSpeed=look.speed;d.multicolour=look.colour==7
        d.color=look.colour<7 && look.colour<palette.count ? palette[look.colour]:RGB(r:255,g:255,b:255)
        d.liveBrightness=Look.brightnessLevels[min(max(look.brightness,0),4)]
        return d
    }
}

/// One-time check of which way speed goes, on the user's own keyboard.
struct SpeedCheck:View {
    @ObservedObject var model:AppModel
    @AppStorage("speedFaster") var speedFaster=""
    @State var original:LightingBlock?
    @State var showing:Int?
    var effect:Int {let e=original?.effect ?? 16;return e==1 || Look.reactiveEffects.contains(e) ? 16:e}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("ONE-TIME CHECK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Which one is faster on your keyboard?").font(.title2.weight(.semibold))
            Text("Speed is stored as 0–4, but which end is faster isn't confirmed. Show A and B on your F65 and watch the keyboard, not this screen. Each is one lighting save; your own settings are put back when you finish.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:12) {
                Button {show(1)} label:{Label("Show A · speed 1",systemImage:showing==1 ? "eye.fill":"eye")}.buttonStyle(.bordered).tint(showing==1 ? Theme.accent:nil)
                Button {show(3)} label:{Label("Show B · speed 3",systemImage:showing==3 ? "eye.fill":"eye")}.buttonStyle(.bordered).tint(showing==3 ? Theme.accent:nil)
                Text("using \(LightingBlock.names[effect-1])").font(.caption).foregroundStyle(.secondary)
            }.disabled(!model.canWrite)
            Divider()
            HStack {
                Button("A was faster"){finish("lower")}.disabled(showing==nil)
                Button("B was faster"){finish("higher")}.disabled(showing==nil)
                Button("Can't tell"){finish(nil)}
                Spacer()
                Button("Cancel"){finish(nil)}.keyboardShortcut(.cancelAction)
            }
            if !speedFaster.isEmpty {Text("Already checked: higher numbers are \(speedFaster=="higher" ? "faster":"slower"). Answering again replaces it.").font(.caption).foregroundStyle(.secondary)}
        }
        .padding(24).frame(width:520)
        .onAppear{original=model.lighting}
    }
    func show(_ speed:Int) {
        guard var b=original else {return}
        try? b.setEffect(effect);try? b.setSlot(effect,brightness:max(b.brightness(effect),2),speed:speed,colour:b.colour(effect))
        model.setLighting(b);showing=speed
    }
    func finish(_ answer:String?) {
        if let answer {speedFaster=answer;model.show("Speed now reads \(answer=="higher" ? "Slower → Faster":"Faster → Slower")")}
        if showing != nil,let o=original {model.setLighting(o)}
        model.speedCheck=false
    }
}
