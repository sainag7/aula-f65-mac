// HID device handling and the 20 fps frame loop. Everything here runs on one serial queue.

import Foundation
import IOKit.hid

enum Mode: String, CaseIterable {
    case off, solid, wave, custom
    var title: String {
        switch self {
        case .off: return "Off"
        case .solid: return "Solid colour"
        case .wave: return "Rainbow wave"
        case .custom: return "Custom layout"
        }
    }
}

enum ConnectionPref: String, CaseIterable {
    case auto, cable, receiver
    var title: String {
        switch self {
        case .auto: return "Automatic (prefer cable)"
        case .cable: return "USB cable only"
        case .receiver: return "2.4G receiver only"
        }
    }
}

enum LinkKind: Equatable {
    case cable, receiver
    var title: String { self == .cable ? "Cable" : "2.4G" }
}

struct Settings {
    var mode: Mode = .wave
    var color = RGB(r: 160, g: 0, b: 255)
    var brightness = 1.0
    var paused = false
    var pref: ConnectionPref = .auto
    var layout = LayoutSpec()
}

struct EngineStatus: Equatable {
    var link: LinkKind?
    var cablePresent = false
    var receiverPresent = false
    var streaming = false
    var message: String?            // error / hint
    var unknownKeys: [String] = []
    var keyMapSource = "built-in"
}

func debugLog(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["F65_DEBUG"] != nil {
        FileHandle.standardError.write(("[f65] " + s() + "\n").data(using: .utf8)!)
    }
}

private func intProp(_ d: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0
}

private final class Link {
    let dev: IOHIDDevice
    let kind: LinkKind
    var failures = 0

    init(dev: IOHIDDevice, kind: LinkKind) { self.dev = dev; self.kind = kind }

    func send(_ colors: [RGB], slots: [Int]) -> Bool {
        switch kind {
        case .cable:
            let p = CableProtocol.frame(colors)
            return p.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, CFIndex(CableProtocol.reportID), $0.baseAddress!, p.count)
            } == kIOReturnSuccess
        case .receiver:
            // Only live-frame output reports ever go to the receiver; nothing else is sent.
            // 2 ms between reports: back-to-back reports get dropped by the receiver (keys stall, then
            // jump). Picked by eye on the F65; a 10-report frame then takes ~40 ms, inside a 50 ms tick.
            for (i, r) in ReceiverProtocol.reports(colors, slots: slots).enumerated() {
                if i > 0 { usleep(2_000) }
                let ok = r.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(ReceiverProtocol.reportID), $0.baseAddress!, r.count)
                } == kIOReturnSuccess
                if !ok { return false }
            }
            return true
        }
    }

    /// Cable only: read the base-layer key map (504 bytes).
    func readKeyMap() -> KeyMap? {
        guard kind == .cable else { return nil }
        let req = CableProtocol.keyMapRequest
        for _ in 0..<3 {
            let r1 = req.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, CFIndex(CableProtocol.reportID), $0.baseAddress!, req.count)
            }
            if r1 != kIOReturnSuccess { usleep(70_000); continue }
            usleep(20_000)
            var buf = [UInt8](repeating: 0, count: CableProtocol.reportSize)
            var len = CFIndex(buf.count)
            let r2 = buf.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(CableProtocol.reportID), $0.baseAddress!, &len)
            }
            if r2 != kIOReturnSuccess || len < 8 + KeyMap.byteCount { usleep(70_000); continue }
            guard let map = KeyMap(bytes: Array(buf[8..<(8 + KeyMap.byteCount)])) else { continue }
            // Sanity check: a real map has Esc in slot 1 and plenty of keys.
            if map.entry(1) == [0, 0, 0, 0x29] && map.litSlots.count >= 40 { return map }
            debugLog("key map reply looked wrong: \(buf[0..<16].map { String(format: "%02x", $0) }.joined(separator: " "))")
            usleep(70_000)
        }
        return nil
    }

    func close() { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
}

final class Engine: @unchecked Sendable {
    static let fps = 20.0

    private let q = DispatchQueue(label: "local.f65.lighting.io", qos: .userInteractive)
    private var manager: IOHIDManager?
    private var present = Set<IOHIDDevice>()
    private var link: Link?
    private var settings = Settings()
    private var suspended = false
    private var timer: DispatchSourceTimer?
    private var retryAt = Date.distantPast
    private var keyMap: KeyMap
    private var layoutFrame = [RGB](repeating: .black, count: KeyMap.slotCount)
    private let start = Date()
    private var status = EngineStatus()
    private var framesSent = 0
    private var permissionAsked = false

    /// Called on the main queue whenever the status changes.
    var onStatus: ((EngineStatus) -> Void)?

    init() {
        if let cached = KeyMap.loadCached() {
            keyMap = cached
            status.keyMapSource = "cached"
        } else {
            keyMap = KeyMap.fallback
        }
    }

    // MARK: Public API (any thread)

    func start(with s: Settings) {
        q.async {
            self.settings = s
            self.relayout()
            self.setUpManager()
            self.updateTimer()
            self.publish()
        }
    }

    func update(_ s: Settings) {
        q.async {
            let prefChanged = s.pref != self.settings.pref
            let layoutChanged = s.layout != self.settings.layout
            self.settings = s
            if layoutChanged { self.relayout() }
            if prefChanged { self.dropLink(retryIn: 0) }
            self.updateTimer()
            self.publish()
        }
    }

    /// System sleep / display sleep: stop streaming so the keyboard can fall back to its own effect.
    func setSuspended(_ v: Bool) {
        q.async {
            self.suspended = v
            if !v { self.retryAt = .distantPast }
            self.updateTimer()
            self.publish()
        }
    }

    // MARK: HID manager

    private func setUpManager() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x258A, kIOHIDProductIDKey: 0x010C],
            [kIOHIDVendorIDKey: 0x3554, kIOHIDProductIDKey: 0xFA09, kIOHIDPrimaryUsagePageKey: 0xFF02],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().deviceAdded(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(dev)
        }, ctx)
        IOHIDManagerSetDispatchQueue(m, q)
        IOHIDManagerActivate(m)
        manager = m
    }

    private func kind(of d: IOHIDDevice) -> LinkKind? {
        let vid = intProp(d, kIOHIDVendorIDKey), pid = intProp(d, kIOHIDProductIDKey)
        if vid == 0x258A && pid == 0x010C && intProp(d, kIOHIDMaxFeatureReportSizeKey) >= 520 { return .cable }
        if vid == 0x3554 && pid == 0xFA09 && intProp(d, kIOHIDPrimaryUsagePageKey) == 0xFF02
            && intProp(d, kIOHIDMaxOutputReportSizeKey) >= 20 { return .receiver }
        return nil
    }

    private func deviceAdded(_ d: IOHIDDevice) {
        guard let k = kind(of: d) else { return }
        present.insert(d)
        debugLog("device added: \(k.title)")
        // A cable showing up beats an active receiver link in automatic mode.
        if k == .cable, settings.pref == .auto, link?.kind == .receiver { dropLink(retryIn: 0) }
        retryAt = .distantPast
        publish()
    }

    private func deviceRemoved(_ d: IOHIDDevice) {
        present.remove(d)
        if link?.dev == d {
            debugLog("active device removed")
            link = nil
            retryAt = Date().addingTimeInterval(0.5)
        }
        publish()
    }

    private func allowed(_ k: LinkKind) -> Bool {
        switch settings.pref {
        case .auto: return true
        case .cable: return k == .cable
        case .receiver: return k == .receiver
        }
    }

    private func dropLink(retryIn secs: Double) {
        link?.close()
        link = nil
        retryAt = Date().addingTimeInterval(secs)
    }

    private func ensureLink() {
        guard link == nil, Date() >= retryAt else { return }
        let candidates = present.compactMap { d -> (IOHIDDevice, LinkKind)? in
            guard let k = kind(of: d), allowed(k) else { return nil }
            return (d, k)
        }.sorted { a, _ in a.1 == .cable }
        for (d, k) in candidates {
            let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
            if r == kIOReturnSuccess {
                let l = Link(dev: d, kind: k)
                link = l
                status.message = nil
                debugLog("opened \(k.title)")
                if k == .cable {
                    if let map = l.readKeyMap() {
                        if map.bytes != keyMap.bytes { map.saveToCache() }
                        keyMap = map
                        status.keyMapSource = "read from keyboard"
                        debugLog("key map read: \(map.litSlots.count) lit slots")
                    } else {
                        debugLog("key map read failed, using \(status.keyMapSource)")
                    }
                    relayout()
                }
                return
            }
            debugLog("open \(k.title) failed: 0x\(String(UInt32(bitPattern: r), radix: 16))")
            if r == kIOReturnNotPermitted {
                status.message = "Needs Input Monitoring permission"
                if !permissionAsked {
                    permissionAsked = true
                    DispatchQueue.main.async { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
                }
            } else {
                status.message = "Could not open the keyboard, retrying"
            }
        }
        retryAt = Date().addingTimeInterval(2)
    }

    // MARK: Frame loop

    private var wantsStreaming: Bool { settings.mode != .off && !settings.paused && !suspended }

    private func updateTimer() {
        if wantsStreaming, timer == nil {
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: 1.0 / Engine.fps, leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        } else if !wantsStreaming, let t = timer {
            t.cancel()
            timer = nil
        }
    }

    private func tick() {
        guard wantsStreaming else { return }
        ensureLink()
        guard let l = link else { publish(); return }
        let colors = render(Date().timeIntervalSince(start), receiver: l.kind == .receiver)
        // 2.4G has a radio budget of roughly 70 reports/s on the F65 (more makes keys glitch and the
        // keyboard drop back to its saved effect). So over the receiver, send only when the picture
        // changes, plus a keep-alive every 0.4 s (the keyboard reverts ~1 s after frames stop).
        if l.kind == .receiver, colors == lastSentFrame, Date().timeIntervalSince(lastSendTime) < 0.4 {
            publish(); return
        }
        if l.send(colors, slots: keyMap.litSlots) {
            lastSentFrame = colors
            lastSendTime = Date()
            l.failures = 0
            framesSent += 1
            if status.message != nil { status.message = nil }
            if framesSent == 1 || framesSent % 100 == 0 { debugLog("frames sent: \(framesSent) via \(l.kind.title)") }
        } else {
            l.failures += 1
            debugLog("frame failed (\(l.failures) in a row)")
            if l.failures >= 20 {   // ~1 s of failures: keyboard asleep, unplugged or busy
                debugLog("\(l.kind.title) not responding, reopening")
                status.message = "Keyboard not responding, retrying"
                dropLink(retryIn: 2)
            }
        }
        publish()
    }

    private func relayout() {
        let r = settings.layout.resolve(keyMap)
        layoutFrame = r.frame
        status.unknownKeys = r.unknown
    }

    private var lastSentFrame: [RGB] = []
    private var lastSendTime = Date.distantPast

    /// Over 2.4G the wave is a smooth flow at 20 fps: each column its own exact hue (≤ 16 colours, so
    /// ~132 bytes / 10 reports per frame), half a rainbow cycle per second. Picked by eye on the F65
    /// over stepped bands and 12/16 fps.
    private static let receiverWaveCyclesPerSecond = 0.5

    private func render(_ t: Double, receiver: Bool = false) -> [RGB] {
        var frame: [RGB]
        switch settings.mode {
        case .off:
            frame = [RGB](repeating: .black, count: KeyMap.slotCount)
        case .solid:
            frame = [RGB](repeating: settings.color, count: KeyMap.slotCount)
        case .custom:
            frame = layoutFrame
        case .wave where receiver:
            frame = (0..<KeyMap.slotCount).map { slot in
                var h = Double(slot / 6) / 16 - t * Engine.receiverWaveCyclesPerSecond
                h -= h.rounded(.down)
                return RGB(hue: h)
            }
        case .wave:
            let cols = keyMap.litSlots.map { $0 / 6 }
            let lo = Double(cols.min() ?? 0), span = Double((cols.max() ?? 15) - (cols.min() ?? 0) + 1)
            frame = (0..<KeyMap.slotCount).map { slot in
                RGB(hue: (Double(slot / 6) - lo) / span - t * 0.25)
            }
        }
        frame[0] = .black
        return settings.brightness < 0.999 ? frame.map { $0.scaled(settings.brightness) } : frame
    }

    private func publish() {
        status.link = link?.kind
        status.cablePresent = present.contains { kind(of: $0) == .cable }
        status.receiverPresent = present.contains { kind(of: $0) == .receiver }
        status.streaming = wantsStreaming && link != nil
        guard status != lastPublished else { return }
        lastPublished = status
        let s = status
        DispatchQueue.main.async { [onStatus] in onStatus?(s) }
    }

    private var lastPublished: EngineStatus?
}
