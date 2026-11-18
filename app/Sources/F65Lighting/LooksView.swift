import SwiftUI
import AppKit
import F65Kit

extension RGB {
    var color:Color {Color(.sRGB,red:Double(r)/255,green:Double(g)/255,blue:Double(b)/255,opacity:1)}
    init(_ color:Color) {let c=NSColor(color).usingColorSpace(.sRGB) ?? .black;self.init(r:UInt8(max(0,min(255,c.redComponent*255))),g:UInt8(max(0,min(255,c.greenComponent*255))),b:UInt8(max(0,min(255,c.blueComponent*255))))}
}

// MARK: - Flat board drawing (thumbnails, Studio, menu images)

enum KeyLabel {
    static let names=["d1":"1","d2":"2","d3":"3","d4":"4","d5":"5","d6":"6","d7":"7","d8":"8","d9":"9","d0":"0","minus":"-","equal":"=","bksp":"Backspace","lbr":"[","rbr":"]","bslash":"\\","semi":";","quote":"'","comma":",","period":".","slash":"/","lshift":"Shift","rshift":"Shift","lctrl":"Ctrl","rctrl":"Ctrl","lwin":"Win","lalt":"Alt","pgup":"PgUp","pgdn":"PgDn","up":"↑","down":"↓","left":"←","right":"→","caps":"Caps","esc":"Esc","del":"Del","enter":"Enter","space":"","tab":"Tab","end":"End","fn":"Fn"]
    static func short(_ id:String)->String {names[id] ?? id.uppercased()}
    static func long(_ id:String)->String {
        let n=["lshift":"Left Shift","rshift":"Right Shift","lctrl":"Left Ctrl","rctrl":"Right Ctrl","space":"Space","up":"Up arrow","down":"Down arrow","left":"Left arrow","right":"Right arrow","caps":"Caps Lock","bksp":"Backspace","del":"Delete","pgup":"Page Up","pgdn":"Page Down"]
        return n[id] ?? short(id)
    }
}

struct BoardStyle {
    var legends=false
    var glow=false
    var selection:Set<String>=[]
    var ring:String?
    var marked:Set<String>=[]
    var locked:Set<String>=[]
    var pad=0.3
}

enum Board {
    static let base=RGB(r:34,g:35,b:39)
    static func metrics(_ size:CGSize,pad:Double)->(u:Double,ox:Double,oy:Double) {
        let u=min(size.width/(16+2*pad),size.height/(5+2*pad))
        return (u,(size.width-16*u)/2,(size.height-5*u)/2)
    }
    static func rect(_ k:KeyPosition,_ m:(u:Double,ox:Double,oy:Double))->CGRect {
        let inset=m.u*0.06
        return CGRect(x:m.ox+k.x*m.u+inset,y:m.oy+(k.cy-0.5)*m.u+inset,width:k.width*m.u-2*inset,height:m.u-2*inset)
    }
    static func key(at p:CGPoint,size:CGSize,pad:Double)->KeyPosition? {
        let m=metrics(size,pad:pad)
        return KeyGeometry.keys.first {rect($0,m).insetBy(dx:-2,dy:-2).contains(p)}
    }
    /// Key fill: the lit colour at full strength, blended over the unlit cap by how bright it is.
    static func fill(_ c:RGB)->RGB {
        let peak=Double(max(c.r,c.g,c.b))
        guard peak>2 else {return base}
        let t=min(1,peak/255*1.15),k=255/peak
        func mix(_ a:UInt8,_ b:UInt8)->UInt8 {UInt8(max(0,min(255,Double(a)+(min(255,Double(b)*k)-Double(a))*t)))}
        return RGB(r:mix(base.r,c.r),g:mix(base.g,c.g),b:mix(base.b,c.b))
    }
    static func draw(_ g:GraphicsContext,_ size:CGSize,frame:[RGB]?,style:BoardStyle) {
        let m=metrics(size,pad:style.pad)
        let plate=CGRect(x:m.ox-0.28*m.u,y:m.oy-0.28*m.u,width:16.56*m.u,height:5.56*m.u)
        g.fill(Path(roundedRect:plate,cornerRadius:0.3*m.u),with:.color(Color(red:0.09,green:0.09,blue:0.1)))
        if style.glow,let frame {
            var glow=g;glow.addFilter(.blur(radius:m.u*0.35))
            for k in KeyGeometry.keys {let c=frame[k.slot];if max(c.r,c.g,c.b)>20 {glow.fill(Path(roundedRect:rect(k,m),cornerRadius:m.u*0.15),with:.color(c.color.opacity(0.55)))}}
        }
        for k in KeyGeometry.keys {
            let r=rect(k,m),c=frame.map{fill($0[k.slot])} ?? base
            g.fill(Path(roundedRect:r,cornerRadius:m.u*0.12),with:.color(c.color))
            if style.legends {
                let l=KeyLabel.short(k.id)
                if !l.isEmpty {
                    let lum=Double(c.r)*0.3+Double(c.g)*0.59+Double(c.b)*0.11
                    let text=Text(l).font(.system(size:max(7,m.u*(l.count>3 ? 0.19:0.27)),weight:.semibold)).foregroundColor(lum>150 ? Color.black.opacity(0.85):Color.white.opacity(0.85))
                    g.draw(text,at:CGPoint(x:r.minX+m.u*0.1,y:r.minY+m.u*0.08),anchor:.topLeading)
                }
            }
            if style.marked.contains(k.id) {g.fill(Path(ellipseIn:CGRect(x:r.maxX-m.u*0.22,y:r.minY+m.u*0.08,width:m.u*0.14,height:m.u*0.14)),with:.color(.cyan))}
            if style.locked.contains(k.id) {g.stroke(Path(roundedRect:r.insetBy(dx:1,dy:1),cornerRadius:m.u*0.1),with:.color(.orange.opacity(0.85)),lineWidth:1.5)}
            if style.selection.contains(k.id) {g.stroke(Path(roundedRect:r.insetBy(dx:-1.5,dy:-1.5),cornerRadius:m.u*0.14),with:.color(.accentColor),style:StrokeStyle(lineWidth:2,dash:[4,3]))}
            if style.ring==k.id {g.stroke(Path(roundedRect:r.insetBy(dx:-2,dy:-2),cornerRadius:m.u*0.15),with:.color(.accentColor),lineWidth:2.5)}
        }
    }
}

struct LookThumbnail:View {
    let look:Look
    let palette:[RGB]
    var fps=12.0
    @Environment(\.accessibilityReduceMotion) var reduced
    var body:some View {
        TimelineView(.animation(minimumInterval:1/fps,paused:reduced)) {tl in
            Canvas {g,size in Board.draw(g,size,frame:look.previewFrame(time:reduced ? 4.2:tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:3600),palette:palette),style:BoardStyle(pad:0.25))}
        }
        .background(Color(red:0.04,green:0.04,blue:0.05)).clipShape(RoundedRectangle(cornerRadius:6))
        .accessibilityHidden(true)
    }
}

struct LookBadge:View {
    let look:Look
    var body:some View {
        Label(look.kind == .keyboard ? "On keyboard":"Needs app",systemImage:look.kind == .keyboard ? "keyboard":"macwindow")
            .font(.caption2.weight(.semibold)).labelStyle(.titleAndIcon)
            .padding(.horizontal,7).padding(.vertical,3)
            .foregroundStyle(look.kind == .keyboard ? Color.green:Color.cyan)
            .background((look.kind == .keyboard ? Color.green:Color.cyan).opacity(0.13),in:Capsule())
            .help(look.kind == .keyboard ? "Saved on the keyboard. Works with this app closed, on any computer.":"Drawn by this app. Stops when the app quits.")
    }
}

// MARK: - Looks home

struct LooksView:View {
    @ObservedObject var model:AppModel
    let columns=[GridItem(.adaptive(minimum:165,maximum:240),spacing:10)]
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            if let w=model.waitingLook {Label("\(w.name) is waiting. It applies as soon as your F65 answers.",systemImage:"hourglass").foregroundStyle(.secondary)}
            HStack(alignment:.top,spacing:14) {
                VStack(alignment:.leading,spacing:6) {
                    KeyboardView(model:model).frame(height:300)
                    Text(model.previewLook != nil ? "Previewing \(model.previewLook!.name) · not applied\(model.tryOn && model.canTryOn ? " · showing on your keyboard":"")":"Preview is approximate · hover a look to preview it").font(.caption).foregroundStyle(model.previewLook != nil ? Color.accentColor:.secondary)
                }
                NowCard(model:model).frame(width:250)
            }
            QuickTuneBar(model:model)
            section("Favourites",note:"The menu bar and ⌃⌥⌘L cycle these",looks:model.lookList.filter(\.favourite))
            section("All looks",note:"Hover to preview · click to apply · right-click for more",looks:model.lookList.filter{!$0.favourite},newCard:true)
            OnboardEffectsStrip(model:model)
        }
    }
    @ViewBuilder func section(_ title:String,note:String,looks:[Look],newCard:Bool=false)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.firstTextBaseline){Text(title).font(.headline);Text(note).font(.caption).foregroundStyle(.secondary)}
            if looks.isEmpty && !newCard {Text("Star a look to add it here.").font(.callout).foregroundStyle(.secondary)}
            LazyVGrid(columns:columns,alignment:.leading,spacing:10) {
                ForEach(looks) {LookCard(model:model,look:$0)}
                if newCard {
                    Button {model.section="Studio"} label:{
                        VStack(spacing:8){Image(systemName:"plus").font(.title2);Text("New look in Studio").font(.callout)}.frame(maxWidth:.infinity,minHeight:118)
                            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(style:StrokeStyle(lineWidth:1,dash:[5,4])).foregroundStyle(.secondary))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LookCard:View {
    @ObservedObject var model:AppModel
    let look:Look
    @State var hovering=false
    var isCurrent:Bool {model.currentLook?.id==look.id}
    var body:some View {
        Button {model.apply(look)} label:{
            VStack(alignment:.leading,spacing:7) {
                LookThumbnail(look:look,palette:model.palette).frame(height:62)
                Text(look.name).font(.callout.weight(.semibold)).lineLimit(1)
                HStack{LookBadge(look:look);Spacer();if look.reactsToTyping{Image(systemName:"keyboard.badge.ellipsis").foregroundStyle(.secondary).help("Reacts to typing")}}
            }
            .padding(8).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(isCurrent ? Color.accentColor:(hovering ? Color.secondary.opacity(0.45):Color.secondary.opacity(0.15)),lineWidth:isCurrent ? 2:1))
            .overlay(alignment:.topTrailing) {
                Button {model.toggleFavourite(look.id)} label:{Image(systemName:look.favourite ? "star.fill":"star").font(.caption).padding(6).background(.black.opacity(0.55),in:Circle())}
                    .buttonStyle(.plain).foregroundStyle(look.favourite ? Color.yellow:.white).padding(12)
                    .accessibilityLabel(look.favourite ? "Remove \(look.name) from favourites":"Add \(look.name) to favourites")
            }
            .contentShape(RoundedRectangle(cornerRadius:10))
        }
        .buttonStyle(.plain)
        .onHover {inside in hovering=inside;if model.active {model.previewLook=inside ? look:(model.previewLook?.id==look.id ? nil:model.previewLook)}}
        .contextMenu {
            Button(look.favourite ? "Remove from Favourites":"Add to Favourites"){model.toggleFavourite(look.id)}
            Button("Edit a copy in Studio"){model.studioStart(from:look)}
            Divider()
            Button("Delete",role:.destructive){model.deleteLook(look.id)}
        }
        .accessibilityLabel("\(look.name), \(look.kind == .keyboard ? "on keyboard":"needs app")\(isCurrent ? ", current":"")")
        .accessibilityHint("Applies this look")
    }
}

struct NowCard:View {
    @ObservedObject var model:AppModel
    var body:some View {
        let l=model.previewLook ?? model.currentLook
        VStack(alignment:.leading,spacing:10) {
            Text(model.previewLook != nil ? "HOVERING":"CURRENT LOOK").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let l {
                Text(l.name).font(.title2.weight(.semibold)).lineLimit(2)
                LookBadge(look:l)
                Text(describe(l)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if model.previewLook == nil {
                    HStack {
                        Button {model.studioStart(from:l)} label:{Label("Edit in Studio",systemImage:"paintbrush")}
                        if model.looks.look(l.id)==nil {Button("Save as look"){var c=l;c.id=UUID().uuidString;model.currentLookID=model.looks.add(c).id;model.reloadLooks()}}
                    }.controlSize(.small)
                }
            } else {Text(model.device.link==nil ? "Connect your F65":"Waiting for keyboard").font(.headline);Text("Looks load after the keyboard answers.").foregroundStyle(.secondary)}
            Spacer(minLength:0)
            Toggle(isOn:$model.tryOn){Text("Try on keyboard")}.toggleStyle(.switch).controlSize(.small).disabled(!model.canTryOn)
                .help(model.canTryOn ? "Hovered looks show on your F65 until you move away. Nothing is saved.":"Available on the USB cable, or over 2.4G while the saved effect is Fixed.")
            if !model.canTryOn {Text("Try on works on the cable, or over 2.4G while the saved effect is Fixed.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }
        .padding(14).frame(maxWidth:.infinity,minHeight:300,alignment:.topLeading)
        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
    func describe(_ l:Look)->String {
        if l.kind == .keyboard {return "Saved as \(LightingBlock.names[l.effect-1]) (effect \(l.effect) of 18). Keeps working with the app closed."}
        return "\(l.backgroundName) background\(l.keyColors.isEmpty ? "":" with \(l.keyColors.count) painted key\(l.keyColors.count==1 ? "":"s")"). Drawn by this app at 20 fps."
    }
}

/// All 18 onboard effects, for anyone who wants an effect rather than a look. Uses that effect's saved settings.
struct OnboardEffectsStrip:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.firstTextBaseline){Text("Onboard effects").font(.headline);Text("Each keeps its own brightness, speed and colour on the keyboard").font(.caption).foregroundStyle(.secondary)}
            LazyVGrid(columns:[GridItem(.adaptive(minimum:118),spacing:6)],alignment:.leading,spacing:6) {
                ForEach(1...18,id:\.self) {e in
                    let on = !model.liveActive && model.lighting?.effect==e
                    Button {model.applyEffect(e)} label:{
                        HStack(spacing:6){Text(String(format:"%02d",e)).font(.caption.monospaced()).foregroundStyle(.secondary);Text(LightingBlock.names[e-1]).font(.callout).lineLimit(1);Spacer(minLength:0);if Look.reactiveEffects.contains(e){Image(systemName:"keyboard.badge.ellipsis").font(.caption2).foregroundStyle(.secondary)}}
                            .padding(.horizontal,9).padding(.vertical,7).frame(maxWidth:.infinity,alignment:.leading)
                            .background(on ? Color.accentColor.opacity(0.18):Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:7))
                            .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(on ? Color.accentColor:Color.secondary.opacity(0.15)))
                    }.buttonStyle(.plain)
                    .onHover {inside in if model.active,let led=model.lighting {var l=Look.capture(led);l.effect=e;l.brightness=led.brightness(e);l.speed=led.speed(e);l.colour=led.colour(e);l.name=LightingBlock.names[e-1];model.previewLook=inside ? l:nil}}
                    .help(Look.reactiveEffects.contains(e) ? "Reacts to typing":"Saved on the keyboard")
                }
            }
        }
    }
}

// MARK: - Quick tune

struct QuickTuneBar:View {
    @ObservedObject var model:AppModel
    @AppStorage("speedFaster") var speedFaster=""    // "", "higher" or "lower" once checked on the keyboard
    @State var edgeOpen=false
    var body:some View {
        let app=model.liveActive
        let led=model.lighting
        let e=led?.effect ?? 1
        let cur=model.currentLook
        HStack(alignment:.top,spacing:22) {
            VStack(alignment:.leading,spacing:6) {
                HStack{Text("Brightness").font(.subheadline.weight(.semibold));Spacer();Text(app ? "\(Int((cur?.liveBrightness ?? 1)*100))%":"\(led?.brightness(e) ?? 0) / 4").font(.caption.monospaced()).foregroundStyle(.secondary)}
                if app {
                    Slider(value:Binding(get:{(cur?.liveBrightness ?? 1)*100},set:{model.setBrightness(Int($0))}),in:0...100,step:5){Text("Brightness")}.labelsHidden()
                } else {
                    Slider(value:Binding(get:{Double(led?.brightness(e) ?? 0)},set:{model.setBrightness(Int($0.rounded()))}),in:0...4,step:1){Text("Brightness")} minimumValueLabel:{Text("off").font(.caption2)} maximumValueLabel:{Text("max").font(.caption2)}.labelsHidden()
                }
            }.frame(minWidth:180)
            VStack(alignment:.leading,spacing:6) {
                HStack{Text("Speed").font(.subheadline.weight(.semibold));Spacer()
                    if speedFaster.isEmpty {Button{model.speedCheck=true} label:{Label("direction unconfirmed",systemImage:"questionmark.circle").font(.caption)}.buttonStyle(.link).help("Check once on your keyboard which way is faster")}
                    else {Text("\(app ? cur?.backgroundSpeed ?? 2:led?.speed(e) ?? 0) / 4").font(.caption.monospaced()).foregroundStyle(.secondary)}}
                Slider(value:Binding(get:{Double(app ? cur?.backgroundSpeed ?? 2:led?.speed(e) ?? 0)},set:{model.setSpeed(Int($0.rounded()))}),in:0...4,step:1){Text("Speed")} minimumValueLabel:{Text(speedFaster=="higher" ? "Slower":speedFaster=="lower" ? "Faster":"0").font(.caption2)} maximumValueLabel:{Text(speedFaster=="higher" ? "Faster":speedFaster=="lower" ? "Slower":"4").font(.caption2)}.labelsHidden()
                    .disabled(app && cur?.backgroundEffect==nil && cur?.background != "wave")
            }.frame(minWidth:180)
            VStack(alignment:.leading,spacing:6) {
                Text("Colour").font(.subheadline.weight(.semibold))
                Button {model.colourPopover=true} label:{
                    HStack(spacing:8){swatch(app,led,e,cur);Text(colourName(app,led,e,cur)).lineLimit(1);Image(systemName:"chevron.down").font(.caption2)}
                }.popover(isPresented:$model.colourPopover,arrowEdge:.bottom){ColourChooser(model:model).frame(width:320)}
            }
            VStack(alignment:.leading,spacing:6) {
                Text("Edge glow").font(.subheadline.weight(.semibold))
                Button {edgeOpen=true} label:{HStack(spacing:6){Text(LightingBlock.sideEffectName(led?.side("sideEffect") ?? 0));Image(systemName:"chevron.down").font(.caption2)}}
                    .popover(isPresented:$edgeOpen,arrowEdge:.bottom){EdgeGlowView(model:model).padding(16).frame(width:420)}
                    .disabled(led==nil)
            }
            Spacer(minLength:0)
        }
        .padding(14).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
        .disabled(led==nil && !app)
    }
    @ViewBuilder func swatch(_ app:Bool,_ led:LightingBlock?,_ e:Int,_ cur:Look?)->some View {
        let multi=app ? (cur?.multicolour ?? true) && cur?.background != "solid":(led?.colour(e) ?? 7)==7
        let c=app ? cur?.color ?? .black:(led.map{$0.colour(e)<7 ? model.palette[$0.colour(e)]:.black} ?? .black)
        ZStack{if multi {AngularGradient(colors:[.red,.yellow,.green,.cyan,.blue,.purple,.red],center:.center)} else {c.color}}
            .frame(width:20,height:20).clipShape(RoundedRectangle(cornerRadius:5)).overlay(RoundedRectangle(cornerRadius:5).strokeBorder(Color.primary.opacity(0.3)))
    }
    func colourName(_ app:Bool,_ led:LightingBlock?,_ e:Int,_ cur:Look?)->String {
        if app {return (cur?.multicolour ?? true) && cur?.background != "solid" ? "Multicolour":(cur?.color.hex.uppercased() ?? "")}
        let i=led?.colour(e) ?? 7;return i==7 ? "Multicolour":"Keyboard colour \(i+1)"
    }
}

/// One colour picker for every look. Keyboard looks can only use the keyboard's 7 colours, so a new colour asks how to fit it.
struct ColourChooser:View {
    @ObservedObject var model:AppModel
    @AppStorage("recentColours") var recents=""
    @State var custom=Color.orange
    @State var decide:RGB?
    @State var editing=false
    var body:some View {
        let app=model.liveActive
        let led=model.lighting
        VStack(alignment:.leading,spacing:12) {
            if !app,let led {
                HStack{Text("Keyboard colours").font(.headline);Spacer();Text("the F65 stores 7").font(.caption).foregroundStyle(.secondary)}
                HStack(spacing:8) {
                    ForEach(0..<8,id:\.self){i in
                        Button {decide=nil;model.setColourSlot(i)} label:{
                            ZStack{if i==7 {AngularGradient(colors:[.red,.yellow,.green,.cyan,.blue,.purple,.red],center:.center)} else {model.palette[i].color}}
                                .frame(width:28,height:28).clipShape(RoundedRectangle(cornerRadius:7))
                                .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(led.colour(led.effect)==i ? Color.accentColor:Color.primary.opacity(0.25),lineWidth:led.colour(led.effect)==i ? 2.5:1))
                        }.buttonStyle(.plain).accessibilityLabel(i==7 ? "Multicolour":"Keyboard colour \(i+1)").help(i==7 ? "Multicolour":"Keyboard colour \(i+1)")
                    }
                }
            }
            ColorPicker(app ? "Colour":"Any colour",selection:Binding(get:{custom},set:{custom=$0;picked(RGB($0))}),supportsOpacity:false)
            Text("The colour window has hex values and an eyedropper.").font(.caption).foregroundStyle(.secondary)
            let recent=recents.split(separator:",").compactMap{RGB(string:String($0))}
            if !recent.isEmpty {
                HStack(spacing:6){Text("Recent").font(.caption).foregroundStyle(.secondary);ForEach(recent,id:\.self){c in Button{custom=c.color;picked(c)} label:{RoundedRectangle(cornerRadius:4).fill(c.color).frame(width:20,height:20).overlay(RoundedRectangle(cornerRadius:4).strokeBorder(Color.primary.opacity(0.25)))}.buttonStyle(.plain).accessibilityLabel(c.hex)}}
            }
            if let c=decide,let led {decision(c,led)}
            if !app {Button("Edit keyboard colours…"){editing=true}.disabled(!model.canWrite)}
        }
        .padding(16)
        .onAppear{if let c=model.pendingColour {model.pendingColour=nil;custom=c.color;picked(c)}}
        .sheet(isPresented:$editing){PaletteEditor(model:model,draft:model.palette,open:$editing)}
    }
    func picked(_ c:RGB) {
        remember(c)
        if model.liveActive {model.setLiveColour(c);return}
        if let i=model.palette.firstIndex(of:c) {decide=nil;model.setColourSlot(i)} else {decide=c}
    }
    func remember(_ c:RGB) {
        var list=recents.split(separator:",").map(String.init).filter{$0 != c.hex};list.insert(c.hex,at:0);recents=list.prefix(6).joined(separator:",")
    }
    @ViewBuilder func decision(_ c:RGB,_ led:LightingBlock)->some View {
        let keep=led.colour(led.effect)<7 ? led.colour(led.effect):nil
        let slot=led.leastUsedColourSlot(keeping:nil),users=led.effects(usingColour:slot).map{LightingBlock.names[$0-1]}
        let near=Palette.nearestSlot(to:c,in:model.palette)
        VStack(alignment:.leading,spacing:8) {
            Text("\(c.hex.uppercased()) isn't one of the keyboard's 7 colours.").font(.callout.weight(.semibold))
            Text("Saved looks can only use those 7. Choose how to get it:").font(.caption).foregroundStyle(.secondary)
            option(c,"Replace keyboard colour \(slot+1)",users.isEmpty ? "No other effect uses it":"Also changes \(users.joined(separator:", "))"){model.replacePaletteSlot(slot,with:c);decide=nil}
            option(model.palette[near],"Use the nearest: keyboard colour \(near+1)","Lighting save only"){model.setColourSlot(near);decide=nil}
            option(c,"Make a Needs app look in exactly this colour","Streamed by the app; nothing saved"){model.makeSolidAppLook(c);decide=nil}
            if keep != nil {Text("Your current colour stays in its slot unless you replace that one.").font(.caption2).foregroundStyle(.secondary)}
        }.padding(10).background(Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).strokeBorder(Color.orange.opacity(0.5)))
    }
    func option(_ c:RGB,_ title:String,_ detail:String,_ action:@escaping()->Void)->some View {
        Button(action:action) {
            HStack(spacing:8){RoundedRectangle(cornerRadius:4).fill(c.color).frame(width:16,height:16);VStack(alignment:.leading,spacing:1){Text(title).font(.callout);Text(detail).font(.caption2).foregroundStyle(.secondary)};Spacer(minLength:0)}
                .padding(7).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:7))
        }.buttonStyle(.plain).disabled(!model.canWrite && !title.hasPrefix("Make"))
    }
}

struct PaletteEditor:View {
    @ObservedObject var model:AppModel
    @State var draft:[RGB]
    @Binding var open:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:20){Text("Keyboard colours").font(.title2);Text("The F65 stores 7 colours that its saved effects use. Each one updates all 23 effect groups. Changes save only when you click Save.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            ForEach(0..<7,id:\.self){i in ColorPicker("Keyboard colour \(i+1)",selection:Binding(get:{draft[i].color},set:{draft[i]=RGB($0)}),supportsOpacity:false)}
            if model.device.link == .receiver {Text("For large changes, the USB cable is recommended.").font(.caption).foregroundStyle(.secondary)}
            HStack{Button("Reset to factory"){draft=Palette.factory};Spacer();Button("Cancel"){open=false}.keyboardShortcut(.cancelAction);Button("Save"){model.edit(.palette(draft));open=false}.keyboardShortcut(.defaultAction).disabled(!model.canWrite)}
        }.padding(24).frame(width:430)
    }
}

/// Side light strips: the glow along the bottom-left and bottom-right edges. Saved on the keyboard.
struct EdgeGlowView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        if let led=model.lighting {
            let effect=led.side("sideEffect")
            VStack(alignment:.leading,spacing:14) {
                Text("Edge glow").font(.headline)
                Text("The side light strips along the bottom edges. Saved on the keyboard and separate from the key lighting, so they also run under app looks. Fn + Right Shift steps through them too.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Picker("Edge glow effect",selection:Binding(get:{effect},set:{model.edit(.lighting("sideEffect",$0))})) {
                    ForEach(LightingBlock.sideEffectRange,id:\.self){Text(LightingBlock.sideEffectName($0)).tag($0)}
                }.pickerStyle(.segmented).labelsHidden()
                if effect != 0 {
                    level("Brightness","sideBrightness",led.side("sideBrightness"))
                    if LightingBlock.sideUsesSpeed(effect) {level("Speed","sideSpeed",led.side("sideSpeed"))}
                    if LightingBlock.sideUsesColour(effect) {
                        HStack(spacing:8){Text("Colour").frame(width:80,alignment:.leading);ForEach(0..<8,id:\.self){i in
                            Button {model.edit(.lighting("sideColour",i))} label:{ZStack{if i==7 {AngularGradient(colors:[.red,.yellow,.green,.cyan,.blue,.purple,.red],center:.center)} else {model.palette[i].color}}.frame(width:24,height:24).clipShape(Circle()).overlay(Circle().strokeBorder(led.side("sideColour")==i ? Color.accentColor:Color.primary.opacity(0.25),lineWidth:led.side("sideColour")==i ? 2.5:1))}
                                .buttonStyle(.plain).accessibilityLabel(i==7 ? "Edge glow multicolour":"Edge glow keyboard colour \(i+1)")
                        }}
                    }
                }
            }.disabled(!model.canWrite)
        } else {Text("Edge glow loads after the keyboard answers.").foregroundStyle(.secondary)}
    }
    func level(_ label:String,_ field:String,_ value:Int)->some View {
        HStack{Text(label).frame(width:80,alignment:.leading);Picker(label,selection:Binding(get:{value},set:{model.edit(.lighting(field,$0))})){ForEach(0...4,id:\.self){Text("\($0)").tag($0)}}.pickerStyle(.segmented).labelsHidden().frame(width:220)}
    }
}

struct ToastView:View {
    @ObservedObject var model:AppModel
    @Environment(\.accessibilityReduceMotion) var reduced
    var body:some View {
        if let t=model.toast {
            HStack(spacing:12) {
                Text(t.text).font(.callout)
                if t.undo {Button{model.undo()} label:{Label("Undo",systemImage:"arrow.uturn.backward")}.keyboardShortcut("z",modifiers:.command)}
            }
            .padding(.leading,14).padding(.trailing,t.undo ? 8:14).padding(.vertical,8)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(radius:12,y:6)
            .transition(reduced ? .opacity:.move(edge:.bottom).combined(with:.opacity))
            .id(t.id)
            .accessibilityElement(children:.combine).accessibilityAddTraits(.isStaticText)
        }
    }
}
