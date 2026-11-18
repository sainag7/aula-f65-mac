import SwiftUI
import AppKit
import F65Kit

/// Restore points as a timeline you can recognise: each row is drawn from the lighting it saved.
struct HistoryView:View {
    @ObservedObject var model:AppModel
    @State var rows:[Row]=[]
    @State var files=false
    struct Row:Identifiable {let url:URL;let date:Date?;let look:Look?;var id:URL {url}}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("A restore point is saved automatically before every change. Go back to any of them.").foregroundStyle(.secondary)
                Spacer()
                Button("Back up now"){model.edit(.backup)}.disabled(!model.canWrite)
                Button("Restore point files…"){files=true}
            }
            if rows.isEmpty {Label("No restore points yet. One is made before your first change.",systemImage:"clock.arrow.circlepath").foregroundStyle(.secondary).padding(24)}
            ForEach(rows) {r in
                HStack(spacing:14) {
                    if let l=r.look {LookThumbnail(look:l,palette:model.palette,fps:6).frame(width:150,height:52)} else {RoundedRectangle(cornerRadius:6).fill(.quaternary).frame(width:150,height:52)}
                    VStack(alignment:.leading,spacing:3) {
                        Text(r.look.map{LightingBlock.names[$0.effect-1]} ?? r.url.lastPathComponent).font(.callout.weight(.semibold))
                        Text(r.look.map{"Brightness \($0.brightness) · speed \($0.speed) · \($0.colour==7 ? "multicolour":"keyboard colour \($0.colour+1)")"} ?? "Imported file").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(r.date.map{Self.format($0)} ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Button {model.goBack(to:r.url)} label:{Label("Go back",systemImage:"arrow.uturn.backward")}.disabled(!model.canWrite)
                }
                .padding(10).background(Theme.panel,in:RoundedRectangle(cornerRadius:10))
            }
            Text("Thumbnails are drawn from each restore point's lighting. App looks aren't saved on the keyboard, so they don't appear here; use Undo for those. Going back writes only the parts that differ from now.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
        .task(id:model.points) {load()}
        .sheet(isPresented:$files){VStack(alignment:.leading){RestorePointsView(model:model);HStack{Spacer();Button("Done"){files=false}.keyboardShortcut(.defaultAction)}}.padding(24).frame(width:680,height:520)}
    }
    func load() {
        rows=model.points.prefix(60).map {url in Row(url:url,date:BackupStore.date(of:url),look:model.service.backups.lighting(in:url).map{Look.capture($0)})}
    }
    static func format(_ d:Date)->String {
        let f=DateFormatter();f.doesRelativeDateFormatting=true;f.dateStyle = .short;f.timeStyle = .short;return f.string(from:d)
    }
}

extension AppModel {
    /// Restore only the blocks that differ from what the keyboard has now.
    func goBack(to url:URL) {
        guard let snapshot=device.snapshot else {return}
        do {
            let records=try service.backups.load(url)
            let changed=records.filter {r in snapshot.records.first{$0.cmd==r.cmd && $0.sub==r.sub}?.bytes != r.bytes}
            if changed.isEmpty {show("Already like this restore point");return}
            if changed.contains(where:{$0.cmd==0x41}) {
                let a=NSAlert();a.messageText="This also restores key bindings";a.informativeText="The restore point has different key bindings as well as lighting. They'll be restored too, including any Fn and connection bindings. A fresh restore point is made first.";a.addButton(withTitle:"Go back");a.addButton(withTitle:"Cancel")
                guard a.runModal() == .alertFirstButtonReturn else {return}
            }
            if liveActive {updateLive{$0.mode = .off}}
            edit(.restore(changed));currentLookID=nil
            show("Going back to \(url.lastPathComponent)")
        } catch {device.message=error.localizedDescription}
    }
}
