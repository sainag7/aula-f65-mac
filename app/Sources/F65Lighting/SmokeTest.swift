// Opt-in, mock-only integration harness. It cannot construct a real HID hub.
// Exercises the same observable model and WKWebView used by the native controls.
import AppKit
import WebKit
import F65Kit

@MainActor enum SmokeTest {
    struct Failure:Error {let message:String}
    static func require(_ value:Bool,_ message:String)throws {if !value{throw Failure(message:message)}}
    static func pause(_ seconds:Double) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
    static func ready(_ model:AppModel) async throws {
        for _ in 0..<200 {if !model.busy && model.device.snapshot != nil {return};await pause(0.05)}
        throw Failure(message:"Snapshot or transaction timed out: \(model.device.message)")
    }
    static func edit(_ model:AppModel,_ action:DeviceEdit) async throws {try await ready(model);model.edit(action);await pause(0.05);try await ready(model);try require(!model.device.message.contains("FAILED"),model.device.message)}
    static func web(in view:NSView)->WKWebView? {if let w=view as? WKWebView{return w};for v in view.subviews{if let w=web(in:v){return w}};return nil}
    static func loadedWeb(_ window:MainWindow) async throws -> WKWebView {
        for _ in 0..<100 {if let content=window.window?.contentView,let w=web(in:content),let state=try? await w.evaluateJavaScript("window.f65?.inspect()") as? [String:Any],state["keys"] as? Int==67 {return w};await pause(0.1)}
        throw Failure(message:"Keyboard bridge did not load")
    }
    static func run(model:AppModel,window:MainWindow) async {
        guard model.service.isMock else{return}
        let dir=AppPaths.supportDir.appendingPathComponent("verification")
        var log:[String]=[]
        func pass(_ s:String){log.append("PASS: "+s);print("PASS: "+s)}
        do {
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            model.updateLive{$0.mode = .off};try await ready(model)
            pass("Mock snapshot loads without opening HID devices")
            for section in ["Lighting","Keys","Live lighting","Macros","Restore points","Settings"] {
                model.section=section;await pause(0.4)
                guard let content=window.window?.contentView else{throw Failure(message:"Missing content view")}
                content.layoutSubtreeIfNeeded()
                if let rep=content.bitmapImageRepForCachingDisplay(in:content.bounds){content.cacheDisplay(in:content.bounds,to:rep);if let png=rep.representation(using:.png,properties:[:]){try png.write(to:dir.appendingPathComponent(section.replacingOccurrences(of:" ",with:"-")+".png"))}}
                if ["Lighting","Keys","Live lighting","Settings"].contains(section){_ = try await loadedWeb(window)}
                pass("Native screen renders: "+section)
            }
            var w=try await loadedWeb(window)
            try await w.evaluateJavaScript("window.f65.setState({display:'flat',flatStyle:'out',colourway:'black',camera:'top'});window.f65.setSelected('q');window.f65.setLegends({q:'⌘Q'});window.f65.press('q')")
            let inspected=try await w.evaluateJavaScript("window.f65.inspect()") as! [String:Any]
            try require(inspected["mode"] as? String=="flat" && inspected["selected"] as? String=="q","Flat bridge state")
            pass("Web bridge: 67 keys, flat style, colourway, camera, selection, legends and key echo")
            for style in ["lay","glass","out"] {try await w.evaluateJavaScript("window.f65.setState({display:'flat',flatStyle:'\(style)'});");await pause(0.15)
                let image=try await w.takeSnapshot(configuration:nil);if let data=image.tiffRepresentation,let rep=NSBitmapImageRep(data:data),let png=rep.representation(using:.png,properties:[:]){try png.write(to:dir.appendingPathComponent("keyboard-\(style).png"))}}
            try await w.evaluateJavaScript("window.f65.setState({display:'3d',camera:'three'});");await pause(0.4)
            let image=try await w.takeSnapshot(configuration:nil);if let data=image.tiffRepresentation,let rep=NSBitmapImageRep(data:data),let png=rep.representation(using:.png,properties:[:]){try png.write(to:dir.appendingPathComponent("keyboard-3d.png"))}
            pass("Rendered all three flat styles and 3D camera")
            for pref in [ConnectionPref.cable,.receiver] {
                model.updateLive{$0.pref=pref};await pause(0.1);try await ready(model)
                for e in 1...18 {try await edit(model,.effect(e));try require(model.device.snapshot?.lighting.effect==e,"Effect \(e)")}
                for field in ["brightness","speed","colour"] {let end=field=="colour" ? 7:4;for value in 0...end {try await edit(model,.lighting(field,value));let led=model.device.snapshot!.lighting;let got=field=="brightness" ? led.brightness(18):field=="speed" ? led.speed(18):led.colour(18);try require(got==value,"\(field) \(value)")}}
                var colors=Palette.factory;colors[2]=RGB(r:17,g:33,b:129);try await edit(model,.palette(colors));try require(model.device.snapshot?.palette.colours==colors,"Palette edit")
                try await edit(model,.paletteReset);try require(model.device.snapshot?.palette.colours==Palette.factory,"Palette reset")
                for layer:UInt8 in [0,1] {let original=(layer==0 ? model.device.snapshot!.base:model.device.snapshot!.fn).entry(9)
                    try await edit(model,.remap(slot:9,layer:layer,entry:KeyEntry.named("mute")!,allowProtected:false));try require((layer==0 ? model.device.snapshot!.base:model.device.snapshot!.fn).entry(9).bytes==[2,0,0,0xe2],"Remap")
                    try await edit(model,.remap(slot:9,layer:layer,entry:original,allowProtected:false))}
                let saved=model.device.snapshot!;try await edit(model,.backup);let backup=model.service.backups.list()[0];try await edit(model,.effect(1));try await edit(model,.restore(try model.service.backups.load(backup)));try require(model.device.snapshot==saved,"Restore round trip")
                pass("\(pref.title): 18 effects, every brightness/speed/colour value, palette edit/reset, both-layer remaps and restore")
                try await edit(model,.effect(1));try await edit(model,.lighting("brightness",4))
                for mode in [Mode.solid,.wave,.custom] {model.updateLive{$0.mode=mode;$0.paused=false}
                    // The 5 s keyboard poll briefly pauses streaming; wait for a frame instead of a fixed delay.
                    for _ in 0..<30 {await pause(0.1);if model.frame?.count==126 {break}}
                    try require(model.frame?.count==126,"Live frame \(mode)");try require(model.frame![0].isBlack,"Hidden LED mask")}
                model.updateLive{$0.paused=true};await pause(0.2);try require(model.frame==nil,"Pause stream")
                model.updateLive{$0.mode = .off;$0.paused=false};pass("\(pref.title): Solid, Wave, Custom, Pause and Off")
            }
            model.section="Lighting";await pause(0.3);w=try await loadedWeb(window)
            try await w.evaluateJavaScript("window.f65.setState({reduceMotion:true});window.f65.setActive(false)")
            let state=try await w.evaluateJavaScript("window.f65.inspect()") as! [String:Any];try require(state["active"] as? Bool==false,"Inactive renderer")
            pass("Reduce Motion / inactive rendering bridge")
            window.close();try require(NSApp.activationPolicy() == .accessory,"Close to menu bar");window.open();try require(NSApp.activationPolicy() == .regular,"Open main window")
            pass("Window close/reopen activation policy")
            try log.joined(separator:"\n").write(to:dir.appendingPathComponent("smoke.log"),atomically:true,encoding:.utf8)
            print("SMOKE PASSED: \(log.count) checks. Artifacts: \(dir.path)");NSApp.terminate(nil)
        } catch {
            log.append("FAIL: \(error)");try? log.joined(separator:"\n").write(to:dir.appendingPathComponent("smoke.log"),atomically:true,encoding:.utf8)
            print("SMOKE FAILED: \(error)");model.service.stop();exit(1)
        }
    }
}
