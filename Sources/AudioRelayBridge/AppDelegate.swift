import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let supervisor = Supervisor(wantedInput: nil, wantedOutput: nil)
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var statusTitle: NSTextField?
    private var statusDetail: NSTextField?
    private var loginCheckbox: NSButton?
    private var loginDetail: NSTextField?
    private var pauseButton: NSButton?
    private var menuStatus: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var paused = false
    private var requestingPermission = false
    private var headline = "Starting…"
    private var detail = "Connecting BlackHole to your Mac’s output."
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sleeping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opening a second copy must not create a second audio stream.
        if let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        supervisor.onStatus = { [weak self] message, running in
            self?.showStatus(running ? "Bridge active" : "Waiting for audio", detail: message, running: running)
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true
            self?.supervisor.stopWatching()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.refreshAudio()
        })
        if !UserDefaults.standard.bool(forKey: "hasOpened") {
            showWindow(nil)
            UserDefaults.standard.set(true, forKey: "hasOpened")
        }
        refreshAudio()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard statusItem != nil else { return }
        refreshLoginStatus()
        refreshAudio()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisor.stopWatching()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "AudioRelay Bridge")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menuStatus = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        menuStatus.isEnabled = false
        menu.addItem(menuStatus)
        menu.addItem(.separator())
        addItem("Open AudioRelay Bridge…", action: #selector(showWindow(_:)), to: menu)
        pauseItem = addItem("Pause Bridge", action: #selector(togglePause(_:)), to: menu)
        loginItem = addItem("Launch at Login", action: #selector(toggleLogin(_:)), to: menu)
        menu.addItem(.separator())
        addItem("Sound Settings…", action: #selector(openSoundSettings(_:)), to: menu)
        addItem("Setup & Help…", action: #selector(showWindow(_:)), to: menu)
        menu.addItem(.separator())
        addItem("Quit AudioRelay Bridge", action: #selector(quit(_:)), key: "q", to: menu)
        statusItem.menu = menu
        refreshLoginStatus()
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginStatus()
        refreshAudio()
    }

    private func refreshAudio() {
        guard !sleeping, !paused, !requestingPermission else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            supervisor.startWatching()
        case .notDetermined:
            requestingPermission = true
            showStatus("Permission needed", detail: "Allow microphone access so the bridge can read BlackHole’s virtual audio input.")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.requestingPermission = false
                    self?.refreshAudio()
                }
            }
        case .denied, .restricted:
            supervisor.stopWatching()
            showStatus("Microphone access is off", detail: "Enable AudioRelay Bridge in System Settings → Privacy & Security → Microphone, then reopen the app if macOS asks.")
        @unknown default:
            supervisor.stopWatching()
            showStatus("Permission unavailable", detail: "Check Microphone permissions in System Settings.")
        }
    }

    private func showStatus(_ title: String, detail: String, running: Bool = false) {
        headline = title
        self.detail = detail
        menuStatus?.title = title
        statusTitle?.stringValue = title
        statusDetail?.stringValue = detail
        statusItem?.button?.toolTip = "AudioRelay Bridge — \(title)\n\(detail)"
        statusItem?.button?.image = NSImage(systemSymbolName: running ? "headphones" : "headphones.circle", accessibilityDescription: "AudioRelay Bridge: \(title)")
    }

    @objc private func togglePause(_ sender: Any?) {
        paused.toggle()
        pauseItem.title = paused ? "Resume Bridge" : "Pause Bridge"
        pauseButton?.title = pauseItem.title
        if paused {
            supervisor.stopWatching()
            showStatus("Bridge paused", detail: "Audio is not being forwarded. Resume whenever you need it.")
        } else {
            refreshAudio()
        }
    }

    @objc private func toggleLogin(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            @unknown default:
                throw AudioSetupError(message: "This macOS version returned an unknown login-item status.")
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = "Keep AudioRelay Bridge in your Applications folder and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        let state: NSControl.StateValue = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginItem?.state = state
        loginCheckbox?.state = state
        loginDetail?.stringValue = status == .requiresApproval
            ? "Approval needed in System Settings → General → Login Items."
            : "Start the bridge when you sign in. Quitting stops it until you open it again or sign in next time."
    }

    @objc private func showWindow(_ sender: Any?) {
        if window == nil { buildWindow() }
        refreshLoginStatus()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.isSelectable = true
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 610),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "AudioRelay Bridge"
        window.isReleasedWhenClosed = false
        window.center()
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24)
        ])
        func add(_ view: NSView) {
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        add(label("AudioRelay Bridge", size: 26, weight: .bold))
        add(label("Your audio. Your headphones.", size: 15, secondary: true))
        statusTitle = label(headline, size: 17, weight: .semibold)
        statusDetail = label(detail, secondary: true)
        add(statusTitle!)
        add(statusDetail!)
        let separator = NSBox()
        separator.boxType = .separator
        add(separator)
        add(label("Set up once", size: 15, weight: .semibold))
        add(label("1. Install BlackHole 2ch.\n2. In AudioRelay, set the playback device to BlackHole 2ch.\n3. Choose headphones or speakers in your Mac’s Sound menu."))
        add(label("macOS calls virtual audio capture “microphone access.” The bridge reads BlackHole only; it does not select your physical microphone, record audio, or send it over the network.", secondary: true))
        add(label("For Bluetooth music quality, use your Mac’s built-in microphone instead of your headset’s microphone.", secondary: true))
        let links = NSStackView(views: [button("Get BlackHole…", action: #selector(openBlackHole(_:))), button("Microphone Settings…", action: #selector(openMicrophoneSettings(_:)))])
        links.spacing = 8
        add(links)
        loginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(toggleLogin(_:)))
        add(loginCheckbox!)
        loginDetail = label("", size: 12, secondary: true)
        add(loginDetail!)
        pauseButton = button(paused ? "Resume Bridge" : "Pause Bridge", action: #selector(togglePause(_:)))
        let actions = NSStackView(views: [pauseButton!, button("Quit", action: #selector(quit(_:)))])
        actions.spacing = 8
        add(actions)
        self.window = window
        refreshLoginStatus()
        // Size to content so longer status messages do not hide the controls.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 510, height: max(610, content.fittingSize.height + 56)))
    }

    @objc private func openBlackHole(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!)
    }

    @objc private func openMicrophoneSettings(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openSoundSettings(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
