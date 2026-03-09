import AppKit

// Design goal: run as a lightweight menu bar utility without a dock window.
let app = NSApplication.shared
let delegate = StayApplicationDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
