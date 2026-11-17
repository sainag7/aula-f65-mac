import F65Kit
// F65 Lighting: menu-bar app that streams live per-key lighting to an AULA F65.

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
    _ = delegate
}
