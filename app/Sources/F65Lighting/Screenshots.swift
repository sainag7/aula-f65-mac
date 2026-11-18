// Mock-only: F65_MOCK=1 F65_SHOTS=<folder> saves a PNG of each main-window screen (used for the README).
// Needs Screen Recording permission for whatever launched the app. Never runs against a real keyboard.
import AppKit
import F65Kit

@MainActor enum Screenshots {
    static func pause(_ seconds:Double) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
    static func run(model:AppModel,window:MainWindow,folder:String) async {
        guard model.service.isMock,let win=window.window else {return}
        let dir=URL(fileURLWithPath:folder);try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let original=win.frame
        win.setFrame(NSRect(x:original.minX,y:original.maxY-860,width:1240,height:860),display:true)
        func ready() async {for _ in 0..<200 {if !model.busy && model.device.snapshot != nil {return};await pause(0.05)}}
        func shot(_ name:String,region:Bool=false) async {
            await pause(2.2)
            let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            if region,let screen=win.screen ?? NSScreen.main {
                let f=win.frame;let top=screen.frame.maxY-f.maxY
                p.arguments=["-x","-R\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))",dir.appendingPathComponent(name+".png").path]
            } else {p.arguments=["-x","-o","-l\(win.windowNumber)",dir.appendingPathComponent(name+".png").path]}
            try? p.run();p.waitUntilExit();print("SHOT \(name)")
        }
        func type(_ text:String) {
            guard let target=NSApp.keyWindow else {return}
            for ch in text {
                for kind in [NSEvent.EventType.keyDown,.keyUp] {
                    if let e=NSEvent.keyEvent(with:kind,location:.zero,modifierFlags:[],timestamp:0,windowNumber:target.windowNumber,context:nil,characters:String(ch),charactersIgnoringModifiers:String(ch),isARepeat:false,keyCode:0) {target.sendEvent(e)}
                }
            }
        }
        window.open();await ready()
        model.updateLive{$0.mode = .off;$0.pref = .cable};await ready()
        // A few changes so History has restore points to show.
        for id in ["wheel","breathing","waterfall"] {if let l=model.looks.look(id) {model.apply(l,recordUndo:false);await pause(0.7);await ready()}}
        model.toast=nil
        model.section="Looks";await shot("looks")
        if let l=model.looks.look("wasd") {model.apply(l,recordUndo:false);await pause(0.7);await ready()}
        model.toast=nil;await shot("looks-app-look")
        if let l=model.looks.look("wasd") {model.studioStart(from:l)}
        model.section="Studio";await shot("studio")
        model.previewLook=nil;model.selected="caps";model.section="Keys";await shot("keys")
        model.section="History";await shot("history")
        model.section="Settings";await shot("settings")
        model.section="Looks";await pause(0.5)
        model.commandBar=true;await pause(0.8);type("wasd red");await shot("command-bar",region:true)
        model.commandBar=false;await pause(0.4)
        if let l=model.looks.look("waterfall") {model.apply(l,recordUndo:false);await pause(0.7);await ready()}
        model.updateLive{$0.mode = .off}
        win.setFrame(original,display:true);await pause(0.3)
        print("SHOTS DONE: \(dir.path)");NSApp.terminate(nil)
    }
}
