import AppKit
import SwiftUI
import WebKit
import F65Kit

struct KeyboardView:NSViewRepresentable {
    @ObservedObject var model:AppModel
    @AppStorage("display") var display="3d"
    @AppStorage("flatStyle") var style="lay"
    @AppStorage("camera") var camera="three"
    @AppStorage("colourway") var colourway="white"
    @Environment(\.accessibilityReduceMotion) var reduced
    func makeCoordinator()->Coordinator {Coordinator(model)}
    func makeNSView(context:Context)->WKWebView {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator,name:"f65")
        let web=WKWebView(frame:.zero,configuration:config);web.setValue(false,forKey:"drawsBackground")
        web.navigationDelegate=context.coordinator;context.coordinator.web=web
        model.liveFrameTarget=context.coordinator
        if let url=Bundle.main.url(forResource:"index",withExtension:"html",subdirectory:"keyboard") {web.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent())}
        else {model.webFailure=true}
        context.coordinator.monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak coordinator=context.coordinator] event in
            if let c=coordinator,c.model.active,let id=Self.keyCodes[event.keyCode] {c.call("press",id)}
            return event
        }
        return web
    }
    func updateNSView(_ web:WKWebView,context:Context) {
        let snapshot=model.device.snapshot
        let led=model.lighting
        let e=model.hover ?? led?.effect ?? 1
        let state:[String:Any]=["display":model.webFailure ? "flat":display,"flatStyle":style,"camera":camera,"colourway":colourway,"effect":led?.effect ?? 1,"preview":model.hover as Any? ?? NSNull(),"brightness":min(4,led?.brightness(e) ?? 0),"speed":min(4,led?.speed(e) ?? 0),"colour":min(7,led?.colour(e) ?? 7),"palette":(snapshot?.palette.colours ?? Palette.factory).map{[Int($0.r),Int($0.g),Int($0.b)]},"fnLayer":model.section=="Keys" && model.layer==1,"reduceMotion":reduced]
        var legends:[String:String]=[:]
        if let s=snapshot,model.section=="Keys" {
            let layer=model.layer==0 ? s.base:s.fn
            for id in PhysicalKey.ids {
                let slot=PhysicalKey.slots[id]!,entry=layer.entry(slot)
                if model.layer==1 {legends[id]=entry.empty ? "":Self.short(entry)}
                else if entry.bytes != KeyMap.fallback.entry(slot) {legends[id]=Self.short(entry)}
            }
        }
        let liveSelection=model.section=="Live lighting" ? model.liveSelection.sorted():[]
        let values:[(String,Any)]=[("setState",state),("setLegends",legends),("setSelected",model.section=="Keys" ? model.selected as Any? ?? NSNull():NSNull()),("setSelection",liveSelection),("setActive",model.active)]
        context.coordinator.submit(values)
        if let id=model.verifiedKey {context.coordinator.call("verified",id);DispatchQueue.main.async{model.verifiedKey=nil}}
    }
    static func dismantleNSView(_ view:WKWebView,coordinator:Coordinator) {if let monitor=coordinator.monitor{NSEvent.removeMonitor(monitor)};view.configuration.userContentController.removeScriptMessageHandler(forName:"f65");view.stopLoading()}
    static func short(_ e:KeyEntry)->String {
        if e.empty{return "Off"};if e.bytes[0]==13{return "Fn"};if e.bytes[0]==8{return "System"};if e.bytes[0]==7{return "Light \(e.bytes[3])"}
        return e.description.replacingOccurrences(of:"key: ",with:"").replacingOccurrences(of:"media: ",with:"").replacingOccurrences(of:"L⌘ Cmd",with:"⌘").replacingOccurrences(of:"L⌥ Option",with:"⌥")
    }
    @MainActor final class Coordinator:NSObject,WKScriptMessageHandler,WKNavigationDelegate {
        let model:AppModel
        weak var web:WKWebView?
        var monitor:Any?
        var ready=false
        var evaluating=false
        var pending=""
        var last=""
        init(_ model:AppModel){self.model=model}
        func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
            guard let value=message.body as? [String:Any],let type=value["type"] as? String else{return}
            switch type {
            case "ready":ready=true;last="";flush();liveFrame(model.frame)
            case "keyClicked":
                guard let id=value["id"] as? String,PhysicalKey.slots[id] != nil else{break}
                // Live lighting picks several keys for per-key colours; the Keys page inspects one.
                if model.section=="Live lighting" {model.toggleLiveSelection(id)} else {model.selected=id}
            case "webglFailed":model.webFailure=true
            default:break
            }
        }
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){decisionHandler(navigationAction.request.url?.isFileURL==true ? .allow:.cancel)}
        func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error){model.webFailure=true;model.device.message="Keyboard preview: \(error.localizedDescription)"}
        func encoded(_ value:Any)->String {guard let data=try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys]),let s=String(data:data,encoding:.utf8) else{return "null"};return s}
        func call(_ method:String,_ value:Any){guard ready else{return};web?.evaluateJavaScript("window.f65.\(method)(\(encoded(value)))",completionHandler:nil)}
        func submit(_ values:[(String,Any)]){pending=values.map{"window.f65.\($0.0)(\(encoded($0.1)));"}.joined();flush()}
        /// Live frames bypass SwiftUI: only the newest waits while one is being drawn.
        var framePending:String?
        var frameEvaluating=false
        func liveFrame(_ f:[RGB]?) {
            guard ready else{return}
            if let f {
                var js="window.f65.setLiveFrame([";js.reserveCapacity(1100)
                for (i,id) in PhysicalKey.ids.enumerated() {let c=f[PhysicalKey.slots[id]!];if i>0{js+=","};js+="[\(c.r),\(c.g),\(c.b)]"}
                framePending=js+"])"
            } else {framePending="window.f65.setLiveFrame(null)"}
            flushFrame()
        }
        func flushFrame() {
            guard !frameEvaluating,let js=framePending else{return}
            framePending=nil;frameEvaluating=true
            web?.evaluateJavaScript(js){[weak self] _,_ in self?.frameEvaluating=false;self?.flushFrame()}
        }
        func flush(){guard ready,!evaluating,pending != last else{return};let js=pending;last=js;evaluating=true;web?.evaluateJavaScript(js){[weak self] _,error in guard let self else{return};self.evaluating=false;if let error{self.model.device.message="Keyboard preview: \(error.localizedDescription)"};self.flush()}}
    }
    static let keyCodes:[UInt16:String]=[0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"d1",19:"d2",20:"d3",21:"d4",22:"d6",23:"d5",24:"equal",25:"d9",26:"d7",27:"minus",28:"d8",29:"d0",30:"rbr",31:"o",32:"u",33:"lbr",34:"i",35:"p",36:"enter",37:"l",38:"j",39:"quote",40:"k",41:"semi",42:"bslash",43:"comma",44:"slash",45:"n",46:"m",47:"period",48:"tab",49:"space",51:"bksp",53:"esc",115:"end",116:"pgup",117:"del",119:"end",121:"pgdn",123:"left",124:"right",125:"down",126:"up"]
}
