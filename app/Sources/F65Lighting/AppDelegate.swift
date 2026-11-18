import F65Kit
// Menu-bar UI.

import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = Engine()
    private lazy var model = AppModel(service: engine)
    private var mainWindow: MainWindow?
    private let defaults = ProcessInfo.processInfo.environment["F65_MOCK"] == "1" ? UserDefaults(suiteName:"local.f65.lighting.mock")! : UserDefaults.standard
    private var settings = F65Kit.Settings()
    private var status = EngineStatus()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Looking for keyboard…", action: nil, keyEquivalent: "")
    private let hintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let layoutLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var modeItems: [Mode: NSMenuItem] = [:]
    private var prefItems: [ConnectionPref: NSMenuItem] = [:]
    private var brightnessItems: [Double: NSMenuItem] = [:]
    private let modeMenuItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var layoutWatch: Timer?
    private let favouritesHeader = NSMenuItem(title: "Favourite looks", action: nil, keyEquivalent: "")
    private var favouriteItems: [NSMenuItem] = []
    private var hotKey: EventHotKeyRef?
    private var layoutMTime: Date?

    // MARK: Lifecycle

    private var launchedAtLogin = false
    func applicationWillFinishLaunching(_ note: Notification) {
        // A login-item launch stays menu-bar only; a launch from Finder or `open` shows the window.
        if let e = NSAppleEventManager.shared().currentAppleEvent {
            launchedAtLogin = e.eventID == kAEOpenApplication
                && e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // One instance only: two would fight over the keyboard.
        let me = NSRunningApplication.current
        if !engine.isMock, let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me }) {
            NSApp.terminate(nil)
            return
        }

        loadSettings()
        model.live = settings
        model.onLive = { [weak self] value in self?.settings = value; self?.apply() }
        model.onLogin = { [weak self] in self?.toggleLogin() }
        model.onEditLayout = { [weak self] in self?.editLayout() }
        model.onReloadLayout = { [weak self] in self?.reloadLayout() }
        buildMenu()
        registerHotKey()

        engine.onStatus = { [weak self] s in
            MainActor.assumeIsolated { self?.statusChanged(s) }
        }
        engine.start(with: settings)

        let ws = NSWorkspace.shared.notificationCenter
        for (name, suspend) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
                                (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.setSuspended(suspend) }
            }
        }

        // Pick up edits to layout.json without needing "Reload layout".
        layoutMTime = Self.mtime(AppPaths.layoutURL)
        layoutWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLayoutFile() }
        }
        refreshMenu()
        if !launchedAtLogin { openMainWindow() }
        if engine.isMock, ProcessInfo.processInfo.environment["F65_SMOKE"] == "1", let window=mainWindow {
            Task { await SmokeTest.run(model:model,window:window) }
        }
        if engine.isMock, let folder=ProcessInfo.processInfo.environment["F65_SHOTS"], let window=mainWindow {
            Task { await Screenshots.run(model:model,window:window,folder:folder) }
        }
    }

    // MARK: Settings

    private func loadSettings() {
        if let m = defaults.string(forKey: "mode").flatMap(Mode.init(rawValue:)) { settings.mode = m }
        if let c = defaults.string(forKey: "color").flatMap(RGB.init(string:)) { settings.color = c }
        if defaults.object(forKey: "brightness") != nil {
            settings.brightness = min(1, max(0.1, defaults.double(forKey: "brightness")))
        }
        settings.paused = defaults.bool(forKey: "paused")
        if let p = defaults.string(forKey: "connection").flatMap(ConnectionPref.init(rawValue:)) { settings.pref = p }
        settings.layout = LayoutSpec.load()
        if defaults.object(forKey: "effect") != nil {
            let e = defaults.integer(forKey: "effect")
            if Backgrounds.available.contains(e) { settings.effect = e }
        }
        if defaults.object(forKey: "effectSpeed") != nil { settings.effectSpeed = min(4, max(0, defaults.integer(forKey: "effectSpeed"))) }
        if defaults.object(forKey: "effectMulticolour") != nil { settings.effectMulticolour = defaults.bool(forKey: "effectMulticolour") }
        settings.keyColors = Self.decodeKeyColors(defaults.string(forKey: "keyColors"))
    }

    /// Per-key colours are stored as JSON: {"w": "#ff0000", …}. Unknown keys and bad colours are dropped.
    static func encodeKeyColors(_ colors: [String: RGB]) -> String {
        let obj = colors.mapValues { $0.hex }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodeKeyColors(_ s: String?) -> [String: RGB] {
        guard let data = s?.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        var out: [String: RGB] = [:]
        for (id, hex) in obj where PhysicalKey.slots[id] != nil { if let c = RGB(string: hex) { out[id] = c } }
        return out
    }

    private func apply() {
        defaults.set(settings.mode.rawValue, forKey: "mode")
        defaults.set(settings.color.hex, forKey: "color")
        defaults.set(settings.brightness, forKey: "brightness")
        defaults.set(settings.paused, forKey: "paused")
        defaults.set(settings.pref.rawValue, forKey: "connection")
        defaults.set(settings.effect, forKey: "effect")
        defaults.set(settings.effectSpeed, forKey: "effectSpeed")
        defaults.set(settings.effectMulticolour, forKey: "effectMulticolour")
        defaults.set(Self.encodeKeyColors(settings.keyColors), forKey: "keyColors")
        model.live = settings
        engine.update(settings)
        refreshMenu()
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "F65 Lighting")
            img?.isTemplate = true
            b.image = img
            b.toolTip = "F65 Lighting"
        }
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        hintLine.isEnabled = false
        hintLine.isHidden = true
        let open = NSMenuItem(title: "Open F65…", action: #selector(openMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let command = NSMenuItem(title: "Command…", action: #selector(openCommandBar), keyEquivalent: "k")
        command.target = self
        menu.addItem(command)
        menu.addItem(.separator())
        favouritesHeader.isEnabled = false
        menu.addItem(favouritesHeader)
        let next = NSMenuItem(title: "Next Favourite", action: #selector(nextFavourite), keyEquivalent: "l")
        next.keyEquivalentModifierMask = [.control, .option, .command]
        next.target = self
        menu.addItem(next)
        menu.addItem(.separator())
        menu.addItem(statusLine)
        menu.addItem(hintLine)
        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for m in Mode.allCases {
            let it = NSMenuItem(title: m.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
            modeMenu.addItem(it)
            modeItems[m] = it
        }
        modeMenuItem.submenu = modeMenu
        menu.addItem(NSMenuItem(title: "Live lighting", action: nil, keyEquivalent: ""))
        menu.items.last?.isEnabled = false
        menu.addItem(modeMenuItem)

        let colourItem = NSMenuItem(title: "Choose Colour…", action: #selector(showColourPanel), keyEquivalent: "")
        colourItem.target = self
        menu.addItem(colourItem)

        let briMenu = NSMenu()
        for v in [1.0, 0.75, 0.5, 0.25] {
            let it = NSMenuItem(title: "\(Int(v * 100)) %", action: #selector(pickBrightness(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            briMenu.addItem(it)
            brightnessItems[v] = it
        }
        let briItem = NSMenuItem(title: "Brightness", action: nil, keyEquivalent: "")
        briItem.submenu = briMenu
        menu.addItem(briItem)

        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let edit = NSMenuItem(title: "Edit Layout…", action: #selector(editLayout), keyEquivalent: "e")
        edit.target = self
        menu.addItem(edit)
        let reload = NSMenuItem(title: "Reload Layout", action: #selector(reloadLayout), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        layoutLine.isEnabled = false
        layoutLine.isHidden = true
        menu.addItem(layoutLine)
        menu.addItem(.separator())

        let connMenu = NSMenu()
        for p in ConnectionPref.allCases {
            let it = NSMenuItem(title: p.title, action: #selector(pickConnection(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.rawValue
            connMenu.addItem(it)
            prefItems[p] = it
        }
        let connItem = NSMenuItem(title: "Connection", action: nil, keyEquivalent: "")
        connItem.submenu = connMenu
        menu.addItem(connItem)

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit F65 Lighting", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshFavourites(); refreshMenu() }

    private func refreshMenu() {
        guard statusItem != nil else { return }
        for (m, it) in modeItems { it.state = m == settings.mode ? .on : .off }
        modeItems[.effect]?.title = "Effect: \(Backgrounds.name(settings.effect))"
        for (p, it) in prefItems { it.state = p == settings.pref ? .on : .off }
        for (v, it) in brightnessItems { it.state = abs(v - settings.brightness) < 0.01 ? .on : .off }
        let modeTitle = settings.mode == .effect ? Backgrounds.name(settings.effect) : settings.mode.title
        modeMenuItem.title = "Mode: \(modeTitle)" + (settings.keyColors.isEmpty ? "" : " + \(settings.keyColors.count) key colour\(settings.keyColors.count == 1 ? "" : "s")")
        pauseItem.title = settings.paused ? "Resume" : "Pause"
        pauseItem.isEnabled = settings.mode != .off

        // Status line
        var line: String
        switch status.link {
        case .cable?: line = "Cable"
        case .receiver?: line = "2.4G receiver"
        case nil:
            if status.cablePresent && settings.pref != .receiver { line = "Cable" }
            else if status.receiverPresent && settings.pref != .cable { line = "2.4G receiver" }
            else { line = "Not connected" }
        }
        if line != "Not connected" {
            if status.streaming { line += " — streaming" }
            else if settings.mode == .off { line += " — lighting off" }
            else if settings.paused { line += " — paused" }
            else if let m = status.message { line += " — \(m)" }
            else { line += " — connecting…" }
        } else if let m = status.message {
            line += " (\(m))"
        }
        statusLine.title = line

        let receiverInUse = status.link == .receiver || (status.link == nil && settings.pref == .receiver)
        hintLine.title = "2.4G: keyboard's saved effect must be \"Fixed on\""
        hintLine.isHidden = !receiverInUse

        var layoutNotes: [String] = settings.layout.problems
        if !status.unknownKeys.isEmpty { layoutNotes.append("unknown keys: " + status.unknownKeys.joined(separator: ", ")) }
        layoutLine.title = "Layout: " + layoutNotes.joined(separator: "; ")
        layoutLine.isHidden = layoutNotes.isEmpty

        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: loginItem.state = .on; loginItem.title = "Start at Login"
            case .requiresApproval: loginItem.state = .mixed; loginItem.title = "Start at Login (approve in System Settings)"
            default: loginItem.state = .off; loginItem.title = "Start at Login"
            }
        } else {
            loginItem.isHidden = true
        }

        statusItem.button?.appearsDisabled = !status.streaming
    }

    /// Favourite looks with a small preview, inserted under the "Favourite looks" header.
    private func refreshFavourites() {
        favouriteItems.forEach { menu.removeItem($0) }
        favouriteItems = []
        let favs = model.lookList.filter(\.favourite)
        favouritesHeader.title = favs.isEmpty ? "Favourite looks: star one in the window" : "Favourite looks"
        guard var index = menu.items.firstIndex(of: favouritesHeader) else { return }
        let current = model.currentLook?.id
        for l in favs {
            index += 1
            let it = NSMenuItem(title: l.name + (l.kind == .app ? "  (needs app)" : ""), action: #selector(pickLook(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.id
            it.state = l.id == current ? .on : .off
            it.image = Self.thumbnail(l, palette: model.palette)
            menu.insertItem(it, at: index)
            favouriteItems.append(it)
        }
    }

    static func thumbnail(_ look: Look, palette: [RGB]) -> NSImage? {
        let view = Canvas { g, size in Board.draw(g, size, frame: look.previewFrame(time: 4.2, palette: palette), style: BoardStyle(pad: 0.15)) }
            .frame(width: 54, height: 20).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 3))
        let r = ImageRenderer(content: view)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        return r.nsImage
    }

    @objc private func pickLook(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let l = model.looks.look(id) else { return }
        model.apply(l)
    }
    @objc private func nextFavourite() { model.applyNextFavourite() }
    @objc private func openCommandBar() { openMainWindow(); model.commandBar = true }

    /// ⌃⌥⌘L anywhere: next favourite look.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.model.applyNextFavourite() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey | controlKey), EventHotKeyID(signature: OSType(0x4636354C), id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }

    private func statusChanged(_ s: EngineStatus) {
        status = s
        refreshMenu()
    }

    // MARK: Actions

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) else { return }
        settings.mode = m
        if m != .off { settings.paused = false }
        if m == .custom { settings.layout = LayoutSpec.load(); layoutMTime = Self.mtime(AppPaths.layoutURL) }
        apply()
    }

    @objc private func pickBrightness(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        settings.brightness = v
        apply()
    }

    @objc private func pickConnection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = ConnectionPref(rawValue: raw) else { return }
        settings.pref = p
        apply()
    }

    @objc private func togglePause() {
        settings.paused.toggle()
        apply()
    }

    @objc private func showColourPanel() {
        let p = NSColorPanel.shared
        p.showsAlpha = false
        p.isContinuous = true
        p.color = NSColor(srgbRed: CGFloat(settings.color.r) / 255, green: CGFloat(settings.color.g) / 255,
                          blue: CGFloat(settings.color.b) / 255, alpha: 1)
        p.setTarget(self)
        p.setAction(#selector(colourChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    @objc private func colourChanged(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        func b(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        settings.color = RGB(r: b(c.redComponent), g: b(c.greenComponent), b: b(c.blueComponent))
        settings.mode = .solid
        settings.paused = false
        apply()
    }

    @objc private func editLayout() {
        let url = LayoutSpec.ensureFile()
        let ws = NSWorkspace.shared
        if ws.urlForApplication(toOpen: url) != nil {
            ws.open(url)
        } else if let textEdit = ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            ws.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            ws.activateFileViewerSelecting([url])
        }
    }

    @objc private func reloadLayout() {
        settings.layout = LayoutSpec.load()
        layoutMTime = Self.mtime(AppPaths.layoutURL)
        apply()
        if !settings.layout.problems.isEmpty {
            let a = NSAlert()
            a.messageText = "Problems in layout.json"
            a.informativeText = settings.layout.problems.joined(separator: "\n")
                + "\n\nFormat: {\"rest\": \"#100020\", \"keys\": {\"w\": \"#ff0000\"}}"
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    private func checkLayoutFile() {
        let m = Self.mtime(AppPaths.layoutURL)
        guard m != layoutMTime else { return }
        layoutMTime = m
        settings.layout = LayoutSpec.load()
        apply()
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do {
            switch svc.status {
            case .enabled: try svc.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try svc.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Start at Login"
            a.informativeText = error.localizedDescription
                + "\n\nYou can add the app manually in System Settings → General → Login Items."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        refreshMenu()
    }

    @objc private func openMainWindow() {
        if mainWindow == nil { mainWindow = MainWindow(model: model) }
        mainWindow?.open()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openMainWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { engine.stop() }
    @objc private func quit() { NSApp.terminate(nil) }
}
