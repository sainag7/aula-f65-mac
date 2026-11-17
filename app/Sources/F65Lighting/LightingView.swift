import SwiftUI
import AppKit
import F65Kit

extension RGB {
    var color:Color {Color(.sRGB,red:Double(r)/255,green:Double(g)/255,blue:Double(b)/255,opacity:1)}
    init(_ color:Color) {let c=NSColor(color).usingColorSpace(.sRGB) ?? .black;self.init(r:UInt8(max(0,min(255,c.redComponent*255))),g:UInt8(max(0,min(255,c.greenComponent*255))),b:UInt8(max(0,min(255,c.blueComponent*255))))}
}
struct LightingView:View {
    @ObservedObject var model:AppModel
    @State var editingPalette=false
    @State var draft=Palette.factory
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Onboard lighting").font(.headline)
            Text("Saved on the keyboard. Works with the app closed.").foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:20) {
                VStack(alignment:.leading,spacing:8){KeyboardView(model:model).frame(height:340);Text(model.frame==nil ? "Preview is approximate · hover previews without saving":"Showing live lighting streamed by the app").font(.caption).foregroundStyle(.secondary)}
                inspector.frame(width:215)
            }
            if model.live.mode != .off && !model.live.paused {
                Label(model.device.link == .receiver ? "Live lighting only displays with Fixed on 2.4G. Other effects stop the live stream.":"Live lighting is covering the onboard effect. Pause it to see saved lighting.",systemImage:"info.circle").font(.callout).foregroundStyle(.secondary)
                Button("Pause live lighting"){model.updateLive{$0.paused=true}}
            }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10),count:6),spacing:10) {
                ForEach(1...18,id:\.self){e in
                    Button {model.edit(.effect(e))} label:{
                        VStack(alignment:.leading,spacing:12){HStack{Image(systemName:effectIcon(e));Spacer();if model.device.snapshot?.lighting.effect==e{Image(systemName:"checkmark.circle.fill")}};Text(LightingBlock.names[e-1]).font(.callout.weight(.medium)).lineLimit(2)}
                            .frame(maxWidth:.infinity,minHeight:62,alignment:.leading).padding(12)
                            .background(model.device.snapshot?.lighting.effect==e ? Color.accentColor.opacity(0.15):Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:9))
                            .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(model.hover==e ? Color.accentColor:Color.secondary.opacity(0.15)))
                    }.buttonStyle(.plain).disabled(!model.canWrite).onHover{inside in if model.active && model.canWrite {model.hover=inside ? e:nil}}
                    .help("Preview \(LightingBlock.names[e-1]); click to save to keyboard")
                }
            }
        }.sheet(isPresented:$editingPalette){paletteSheet}
    }
    @ViewBuilder var inspector:some View {
        if let led=model.device.snapshot?.lighting {
            VStack(alignment:.leading,spacing:16){
                Text(led.name).font(.title2.weight(.semibold));Text("Settings saved per effect").font(.caption).foregroundStyle(.secondary)
                level("Brightness",field:"brightness",value:led.brightness(led.effect))
                level("Speed",field:"speed",value:led.speed(led.effect))
                Text("Speed direction unconfirmed").font(.caption).foregroundStyle(.secondary)
                Text("Colour").font(.headline)
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:4),spacing:10){ForEach(0..<8,id:\.self){i in
                    Button {model.edit(.lighting("colour",i))} label:{ZStack{Circle().fill(i<7 ? model.device.snapshot!.palette.colours[i].color:Color.gray);Circle().strokeBorder(Color.primary.opacity(0.25),lineWidth:1);if i==7{Image(systemName:"rainbow").foregroundStyle(.white)};if led.colour(led.effect)==i{Image(systemName:"checkmark.circle.fill").foregroundStyle(.white,.black)}}.frame(width:32,height:32)}.buttonStyle(.plain).accessibilityLabel(i==7 ? "Multicolour":"Palette colour \(i+1)")
                }}
                Button("Edit palette…"){draft=model.device.snapshot!.palette.colours;editingPalette=true}
            }.disabled(!model.canWrite)
        } else {VStack(alignment:.leading,spacing:12){Image(systemName:"keyboard").font(.largeTitle);Text(model.device.link==nil ? "Connect your F65":"Waiting for keyboard").font(.headline);Text("Settings appear after a complete read.").foregroundStyle(.secondary)}}
    }
    func level(_ label:String,field:String,value:Int)->some View {
        VStack(alignment:.leading){Text(label).font(.headline);Picker(label,selection:Binding(get:{value},set:{model.edit(.lighting(field,$0))})){ForEach(0...4,id:\.self){Text("\($0)").tag($0)}}.pickerStyle(.segmented).labelsHidden()}
    }
    var paletteSheet:some View {
        VStack(alignment:.leading,spacing:20){Text("Edit keyboard palette").font(.title2);Text("Each colour updates all 23 effect groups. Changes save only when you click Save.").foregroundStyle(.secondary)
            ForEach(0..<7,id:\.self){i in ColorPicker("Palette colour \(i+1)",selection:Binding(get:{draft[i].color},set:{draft[i]=RGB($0)}),supportsOpacity:false)}
            if model.device.link == .receiver {Text("For large changes, the USB cable is recommended.").font(.caption).foregroundStyle(.secondary)}
            HStack{Button("Reset to factory"){draft=Palette.factory};Spacer();Button("Cancel"){editingPalette=false}.keyboardShortcut(.cancelAction);Button("Save"){model.edit(.palette(draft));editingPalette=false}.keyboardShortcut(.defaultAction).disabled(!model.canWrite)}
        }.padding(24).frame(width:430)
    }
    func effectIcon(_ e:Int)->String {switch e{case 1:return "sun.max";case 2:return "lungs";case 3,6:return "rainbow";case 5:return "drop";case 7,13:return "water.waves";case 8:return "sparkles";case 18:return "cloud.bolt";default:return "lightbulb"}}
}
