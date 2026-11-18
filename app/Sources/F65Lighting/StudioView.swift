import SwiftUI
import F65Kit

/// Paint the keyboard: tools, region chips and a background layer. Everything here is an app look
/// (per-key colours can only be streamed), so it needs the app running.
struct StudioView:View {
    @ObservedObject var model:AppModel
    enum Tool:String,CaseIterable {case brush,fill,select,eyedropper,gradient,eraser
        var symbol:String {switch self {case .brush:return "paintbrush.pointed";case .fill:return "drop.fill";case .select:return "rectangle.dashed";case .eyedropper:return "eyedropper";case .gradient:return "square.stack.3d.forward.dottedline";case .eraser:return "eraser"}}
        var title:String {switch self {case .brush:return "Brush";case .fill:return "Fill";case .select:return "Select";case .eyedropper:return "Eyedropper";case .gradient:return "Gradient (drag from one key to another)";case .eraser:return "Eraser"}}
    }
    @State var tool=Tool.brush
    @State var primary=RGB(r:255,g:30,b:30)
    @State var secondary=RGB(r:120,g:0,b:255)
    @State var selection:Set<String>=[]
    @State var dragStart:KeyPosition?
    /// A brush stroke that starts on a key already in the brush colour clears keys instead (click again to undo a key).
    @State var stroke:Bool?
    @State var marquee:CGRect?
    @State var showOnKeyboard=false
    @Environment(\.accessibilityReduceMotion) var reduced
    let swatches=["#ff1e1e","#ff8000","#ffdc00","#00e65a","#00dcff","#285aff","#a000ff","#ffffff"].compactMap{RGB(string:$0)}
    let pad=0.35

    var body:some View {
        HStack(alignment:.top,spacing:16) {
            VStack(alignment:.leading,spacing:12) {
                HStack{Text("Paint keys over a background. Nothing saves until you save the look.").foregroundStyle(.secondary);Spacer();LookBadge(look:model.draft)}
                toolbar
                regions
                board
                if !selection.isEmpty {selectionBar} else {Text("Drag across keys to paint. Click a painted key again to clear it. Pick a region, then paint it in one click. Gradient: drag from one key to another.").font(.caption).foregroundStyle(.secondary)}
            }.frame(maxWidth:.infinity)
            VStack(alignment:.leading,spacing:12) {
                KeyboardView(model:model).frame(height:170).clipShape(RoundedRectangle(cornerRadius:10))
                Toggle("Show on keyboard while editing",isOn:$showOnKeyboard).toggleStyle(.switch).controlSize(.small).disabled(!model.canTryOn)
                    .help(model.canTryOn ? "Streams the draft to your F65. Nothing is saved.":"Available on the USB cable, or over 2.4G while the saved effect is Fixed.")
                layers
                SideLightsView(model:model,compact:true).padding(12).background(Theme.panel,in:RoundedRectangle(cornerRadius:10))
                budget
                save
            }.frame(width:300)
        }
        .onAppear {model.previewLook=model.draft;syncKeyboard()}
        .onDisappear {model.previewLook=nil;model.tryOn=false}
        .onChange(of:model.draft) {d in model.previewLook=d;syncKeyboard()}
        .onChange(of:showOnKeyboard) {_ in syncKeyboard()}
    }
    func syncKeyboard() {model.tryOn=showOnKeyboard;model.tryOnUpdate()}

    // MARK: Tools
    var toolbar:some View {
        HStack(spacing:6) {
            ForEach(Tool.allCases,id:\.self) {t in
                Button {tool=t} label:{Image(systemName:t.symbol).frame(width:30,height:26)}
                    .buttonStyle(.bordered).tint(tool==t ? Theme.accent:nil).background(tool==t ? Theme.accent.opacity(0.25):.clear,in:RoundedRectangle(cornerRadius:6))
                    .help(t.title).accessibilityLabel(t.title).accessibilityAddTraits(tool==t ? .isSelected:[])
            }
            Divider().frame(height:22)
            ColorPicker("Brush colour",selection:Binding(get:{primary.color},set:{primary=RGB($0)}),supportsOpacity:false).labelsHidden().help("Brush colour")
            Button {swap(&primary,&secondary)} label:{Image(systemName:"arrow.left.arrow.right")}.buttonStyle(.borderless).help("Swap colours")
            ColorPicker("Second colour",selection:Binding(get:{secondary.color},set:{secondary=RGB($0)}),supportsOpacity:false).labelsHidden().help("Second colour (gradient end)")
            ForEach(swatches,id:\.self) {c in
                Button {primary=c} label:{RoundedRectangle(cornerRadius:4).fill(c.color).frame(width:18,height:18).overlay(RoundedRectangle(cornerRadius:4).strokeBorder(primary==c ? Theme.accent:Color.primary.opacity(0.25),lineWidth:primary==c ? 2:1))}
                    .buttonStyle(.plain).accessibilityLabel("Brush colour \(c.hex)")
            }
        }
    }
    var regions:some View {
        HStack(spacing:6) {
            Text("Select").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(KeyRegions.all,id:\.name) {r in Button(r.name){selection=Set(r.ids)}.controlSize(.small)}
        }
    }
    var board:some View {
        GeometryReader {geo in
            TimelineView(.animation(minimumInterval:1/20,paused:reduced)) {tl in
                Canvas {g,size in
                    let t=reduced ? 4.2:tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:3600)
                    Board.draw(g,size,frame:model.draft.previewFrame(time:t,palette:model.palette),style:BoardStyle(legends:true,glow:true,selection:selection,pad:pad))
                    if let m=marquee {g.stroke(Path(m),with:.color(Theme.accent),style:StrokeStyle(lineWidth:1.5,dash:[5,4]))}
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged{v in dragged(v,geo.size)}.onEnded{v in ended(v,geo.size)})
        }
        .frame(height:300).background(Color(red:0.04,green:0.04,blue:0.05),in:RoundedRectangle(cornerRadius:10))
        .accessibilityElement().accessibilityLabel("Keyboard paint board, \(model.draft.keyColors.count) painted keys").accessibilityHint("Use the region buttons for keyboard access")
    }
    func dragged(_ v:DragGesture.Value,_ size:CGSize) {
        if stroke==nil {
            dragStart=Board.key(at:v.startLocation,size:size,pad:pad)
            stroke=tool == .eraser || (tool == .brush && dragStart.map{model.draft.keyColors[$0.id]==primary}==true)
        }
        switch tool {
        case .brush,.eraser:
            guard let k=Board.key(at:v.location,size:size,pad:pad) else {return}
            if stroke==true {if model.draft.keyColors[k.id] != nil {model.draft.keyColors[k.id]=nil}} else if model.draft.keyColors[k.id] != primary {model.draft.keyColors[k.id]=primary}
        case .select:
            let r=CGRect(x:min(v.startLocation.x,v.location.x),y:min(v.startLocation.y,v.location.y),width:abs(v.location.x-v.startLocation.x),height:abs(v.location.y-v.startLocation.y))
            marquee=r
            let m=Board.metrics(size,pad:pad)
            selection=Set(KeyGeometry.keys.filter{Board.rect($0,m).intersects(r)}.map(\.id))
        default:break
        }
    }
    func ended(_ v:DragGesture.Value,_ size:CGSize) {
        defer {dragStart=nil;marquee=nil;stroke=nil}
        let end=Board.key(at:v.location,size:size,pad:pad)
        switch tool {
        case .fill:
            if let k=dragStart {model.draft.keyColors=Paint.flood(from:k.id,colours:model.draft.keyColors,fill:primary)}
        case .eyedropper:
            if let k=dragStart {
                let f=model.draft.previewFrame(time:Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:3600),palette:model.palette)
                let c=model.draft.keyColors[k.id] ?? f[k.slot]
                if !c.isBlack {primary=c};tool = .brush
            }
        case .gradient:
            if let a=dragStart,let b=end,a.id != b.id {
                let ids=selection.isEmpty ? PhysicalKey.ids:Array(selection)
                model.draft.keyColors.merge(Paint.gradient(from:a.id,to:b.id,ids:ids,primary,secondary)){_,new in new}
            }
        case .select:
            if abs(v.translation.width)<3 && abs(v.translation.height)<3,let k=end {if selection.contains(k.id) {selection.remove(k.id)} else {selection.insert(k.id)}}
        default:break
        }
    }
    var selectionBar:some View {
        HStack(spacing:8) {
            Text("\(selection.count) key\(selection.count==1 ? "":"s") selected").font(.callout.weight(.semibold))
            Button {for id in selection {model.draft.keyColors[id]=primary};selection=[]} label:{HStack(spacing:6){RoundedRectangle(cornerRadius:3).fill(primary.color).frame(width:14,height:14);Text("Paint")}}.buttonStyle(.borderedProminent)
            Button("Gradient") {
                let keys=KeyGeometry.keys.filter{selection.contains($0.id)}.sorted{$0.cx<$1.cx}
                if let a=keys.first,let b=keys.last,a.id != b.id {model.draft.keyColors.merge(Paint.gradient(from:a.id,to:b.id,ids:Array(selection),primary,secondary)){_,new in new}}
                selection=[]
            }
            Button("Unpaint") {for id in selection {model.draft.keyColors[id]=nil};selection=[]}
            Spacer()
            Button("Deselect"){selection=[]}.buttonStyle(.borderless)
        }.padding(8).background(Theme.panel,in:RoundedRectangle(cornerRadius:9))
    }

    // MARK: Layers
    var backgrounds:[(String,String)] {[("dark","Dark"),("solid","Solid colour"),("wave","Rainbow wave")]+Backgrounds.available.map{("effect:\($0)",Backgrounds.name($0))}}
    var layers:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Layers · top wins").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack{Image(systemName:"paintbrush.pointed");Text("Paint").font(.callout.weight(.semibold));Spacer();Text("\(model.draft.keyColors.count) keys").font(.caption).foregroundStyle(.secondary);Button("Clear"){model.draft.keyColors=[:]}.controlSize(.small).disabled(model.draft.keyColors.isEmpty)}
            HStack{Image(systemName:"square.grid.3x3.fill");Text("Background").font(.callout.weight(.semibold))}
            Picker("Background",selection:$model.draft.background){ForEach(backgrounds,id:\.0){Text($0.1).tag($0.0)}}.labelsHidden()
            if model.draft.background=="solid" || (model.draft.backgroundEffect != nil && !model.draft.multicolour) {
                ColorPicker("Background colour",selection:Binding(get:{model.draft.color.color},set:{model.draft.color=RGB($0)}),supportsOpacity:false)
            }
            if let e=model.draft.backgroundEffect {
                if !Backgrounds.alwaysMulticolour.contains(e) {Toggle("Multicolour",isOn:$model.draft.multicolour)}
                HStack{Text("Speed");Picker("Speed",selection:$model.draft.backgroundSpeed){ForEach(0...4,id:\.self){Text("\($0)").tag($0)}}.pickerStyle(.segmented).labelsHidden()}
            }
            HStack{Text("Brightness");Slider(value:$model.draft.liveBrightness,in:0.1...1)}
            Text("13 effects can be a background. Flash away, Ripples, Shadow and Reaction react to typing, so they're keyboard looks only.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(12).background(Theme.panel,in:RoundedRectangle(cornerRadius:10))
    }
    @ViewBuilder var budget:some View {
        let used=LiveBudget.pinnedBytes(model.draft.keyColors),cap=LiveBudget.frameBytes
        VStack(alignment:.leading,spacing:6) {
            HStack{Text(model.device.link == .cable ? "USB cable":"2.4G frame").font(.caption.weight(.semibold)).foregroundStyle(.secondary);Spacer();Text(model.device.link == .cable ? "exact":"\(min(used,cap)) / \(cap) bytes").font(.caption.monospaced())}
            if model.device.link == .cable {Text("Over the cable every key gets its exact colour every frame.").font(.caption2).foregroundStyle(.secondary)}
            else {
                GeometryReader{g in HStack(spacing:0){Rectangle().fill(used>cap ? Color.orange:Color.green).frame(width:g.size.width*min(1,Double(used)/Double(cap)));Rectangle().fill(Theme.accent.opacity(0.45))}}.frame(height:8).clipShape(RoundedRectangle(cornerRadius:2))
                Text(used>cap ? "Too many different painted colours for one frame. Similar colours will be merged.":"Painted keys stay exact. The background gets the rest and is simplified when it doesn't fit.").font(.caption2).foregroundStyle(used>cap ? Color.orange:.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }.padding(12).background(Theme.panel,in:RoundedRectangle(cornerRadius:10))
    }
    var save:some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("Look name",text:$model.draft.name).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save look") {let saved=model.looks.add(model.draft);model.reloadLooks();model.previewLook=nil;model.apply(saved);model.draft=Look(name:"My look",kind:.app)}.buttonStyle(.borderedProminent).keyboardShortcut("s",modifiers:.command)
                Button("Apply without saving") {model.previewLook=nil;var d=model.draft;d.id="studio";model.apply(d)}
            }
            Text("Saved looks appear in Looks and can be starred for the menu bar.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
