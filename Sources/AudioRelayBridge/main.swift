import AppKit

// Read-only diagnostics; no permission prompt or audio engine is opened.
if CommandLine.arguments.contains("--list") {
    printDevices(allDevices())
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
