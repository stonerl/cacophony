import CacophonyRouting
import AppKit
import AVKit
import CoreAudio
import Foundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency AVRoutePickerViewDelegate {
    private var statusItem: NSStatusItem!
    private var panelView: PanelView!
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var pickerIsPresentingRoutes = false
    private var lastPickerDismissedAt: TimeInterval = -Double.infinity
    private var lastHasSpeakers: Bool?
    private var lastAutoSwitchFailure: TimeInterval = -Double.infinity
    private var lastNeedsAttention: Bool?
    private var lastStatusIconSide: CGFloat?
    private var lastAppearsDisabled: Bool?
    private var routeChangeObserver: NSObjectProtocol?
    private var isRecoveringAirPlay = false
    private var controller: SystemAudioController!

    private var panel: StatusPanel? { panelView?.panel }

    private let streamingIcon = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "Cacophony")
    private let attentionIcon = NSImage(systemSymbolName: "airplayaudio.badge.exclamationmark", accessibilityDescription: "Cacophony needs attention")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reuse the same context across launches so a picked route can survive
        // an app restart instead of being orphaned on a dead context.
        let defaults = UserDefaults.standard
        var context: NSObject?
        if let savedID = defaults.string(forKey: "contextID") {
            let rehydrated = CACContextForID(savedID)
            // outputContextForID: can hand back a video-typed handle; the
            // audio type is what makes the picker offer multi-select speakers,
            // so only reuse it when the type survived.
            let type = rehydrated.flatMap { CACDeviceProperty($0, "outputContextType") as? String } ?? ""
            if type.localizedCaseInsensitiveContains("audio") {
                context = rehydrated
            }
            alog("rehydrate context \(savedID): \(rehydrated.map(String.init(describing:)) ?? "nil") type=\(type) reused=\(context != nil)")
        }
        if context == nil {
            context = CACDefaultSharedAudioContext() ?? CACCreateAudioContext()
        }
        guard let context else {
            alog("ERROR: no AVOutputContext available")
            NSApp.terminate(nil)
            return
        }
        if let id = CACContextID(context) { defaults.set(id, forKey: "contextID") }
        alog("context \(context) id=\(CACContextID(context) ?? "nil")")
        controller = makeController(context: context)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "Cacophony"
        updateStatusIcon(needsAttention: false)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panelView = PanelView(pickerDelegate: self, contextID: CACContextID(context))
        panelView.canOpenPicker = { [weak self] in
            guard let self, !self.pickerIsPresentingRoutes else { return false }
            return ProcessInfo.processInfo.systemUptime - self.lastPickerDismissedAt > 0.2
        }
        panelView.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        panelView.onDriverAction = { [weak self] in self?.driverAction() }
        panelView.onQuit = { [weak self] in self?.quitApp() }

        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshUI()
            }
        }
        timer.tolerance = 0.5

        observeRouteChanges(for: context)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshUI()
            }
        }

        // Core Audio can block while a HAL driver is loading. Keep that work
        // off the main thread so the menu bar item appears promptly.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var defaultOutput = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectAddPropertyListenerBlock(.system, &defaultOutput, .main) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    DriverManager.noteDefaultOutputChange()
                    self?.refreshUI()
                }
            }
            DriverManager.noteDefaultOutputChange()
        }

        // Streaming is the default; quitting Cacophony is how you opt out.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controller.start()
            self.refreshUI()
        }

        if !DriverManager.isInstalled {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.promptForDriverInstall()
            }
        }
    }

    private func makeController(context: NSObject) -> SystemAudioController {
        let controller = SystemAudioController(context: context)
        controller.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.refreshUI() }
        }
        controller.onNeedsSpeakers = { [weak self] in
            Task { @MainActor [weak self] in self?.showPanel() }
        }
        controller.onConnectionFailure = { [weak self] reason in
            Task { @MainActor [weak self] in self?.recoverAirPlay(reason: reason) }
        }
        return controller
    }

    private func observeRouteChanges(for context: NSObject) {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: .init("AVOutputContextOutputDevicesDidChangeNotification"),
            object: context,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.pickerIsPresentingRoutes {
                    self.panelView.resetPicker()
                }
                self.reconcile()
            }
        }
    }

    private func recoverAirPlay(reason: String) {
        guard !isRecoveringAirPlay else { return }
        isRecoveringAirPlay = true
        defer { isRecoveringAirPlay = false }

        alog("resetting AirPlay context after: \(reason)")
        hidePanel()

        controller.stop()

        guard let context = CACCreateAudioContext() ?? CACDefaultSharedAudioContext() else {
            alog("could not create replacement audio context")
            return
        }

        let contextID = CACContextID(context)
        let defaults = UserDefaults.standard
        if let contextID {
            defaults.set(contextID, forKey: "contextID")
        } else {
            defaults.removeObject(forKey: "contextID")
        }

        if let contextID {
            panelView.updateOutputContextID(contextID)
        }

        controller = makeController(context: context)
        observeRouteChanges(for: context)
        lastHasSpeakers = nil
        lastAutoSwitchFailure = -Double.infinity
        controller.start()
        refreshUI()
    }

    private func reconcile() {
        controller.tick()
        refreshUI()
    }

    private func refreshUI() {
        let devices = CACContextOutputDevices(controller.context)
        let hasSpeakers = !devices.isEmpty
        syncSystemOutput(hasSpeakers: hasSpeakers)

        let installed = DriverManager.isInstalled
        let device = DriverManager.device
        let isDefault = DriverManager.isDefaultOutput

        let needsAttention = !installed || device == nil || controller.lastError != nil

        if !installed {
            panelView.updateDriverTitle("Install Driver…")
        } else if DriverManager.isUpdateAvailable {
            panelView.updateDriverTitle("Update Driver…")
        } else {
            panelView.updateDriverTitle("Uninstall Driver…")
        }
        panelView.updateLoginState(SMAppService.mainApp.status == .enabled)
        panelView.updateCaption(hasSpeakers: hasSpeakers, isDefault: isDefault)

        // Full-strength icon while streaming, dimmed while idle.
        updateStatusIcon(needsAttention: needsAttention)
        let appearsDisabled = !controller.isStreaming && !needsAttention
        if lastAppearsDisabled != appearsDisabled {
            lastAppearsDisabled = appearsDisabled
            statusItem.button?.appearsDisabled = appearsDisabled
        }

        refreshSpeakerPanel(devices: devices, force: false)
    }

    private func updateStatusIcon(needsAttention: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let side: CGFloat = (screen?.safeAreaInsets.top ?? 0) > 0 ? 16 : 14

        guard lastNeedsAttention != needsAttention || lastStatusIconSide != side else { return }
        lastNeedsAttention = needsAttention
        lastStatusIconSide = side

        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
        let base = (needsAttention ? attentionIcon : streamingIcon) ?? streamingIcon
        let image = base?.withSymbolConfiguration(configuration)
        image?.size = NSSize(width: side, height: side)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    private func syncSystemOutput(hasSpeakers: Bool) {
        guard lastHasSpeakers != hasSpeakers else { return }

        if hasSpeakers {
            guard DriverManager.device != nil else {
                lastHasSpeakers = nil
                return
            }
            if DriverManager.isDefaultOutput {
                lastHasSpeakers = true
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastAutoSwitchFailure >= 5 else { return }

            do {
                try DriverManager.setAsDefaultOutput()
                lastHasSpeakers = true
                lastAutoSwitchFailure = -Double.infinity
                alog("auto system output -> Cacophony")
            } catch {
                lastAutoSwitchFailure = now
                alog("auto system output -> Cacophony failed: \(error.localizedDescription)")
            }
        } else if DriverManager.isDefaultOutput {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastAutoSwitchFailure >= 5 else { return }

            DriverManager.restorePreviousOutputIfNeeded()
            if DriverManager.isDefaultOutput {
                lastAutoSwitchFailure = now
                alog("auto system output restore failed")
            } else {
                lastHasSpeakers = false
                lastAutoSwitchFailure = -Double.infinity
                alog("auto system output -> previous")
            }
        } else {
            lastHasSpeakers = false
        }
    }

    private func promptForDriverInstall() {
        let alert = NSAlert()
        alert.messageText = "Install the Cacophony audio driver?"
        alert.informativeText = "Cacophony needs a CoreAudio driver to appear as a system output. Cacophony installs a background helper for this; approve it in System Settings if prompted. Core Audio restarts, so audio stops for a moment."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            installDriver()
        }
    }

    private func driverAction() {
        if !DriverManager.isInstalled || DriverManager.isUpdateAvailable {
            installDriver()
        } else {
            uninstallDriver()
        }
    }

    private func installDriver() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await DriverManager.install()
                let alert = NSAlert()
                alert.messageText = "Cacophony driver installed"
                alert.informativeText = "Cacophony will detect the device automatically. Select speakers when it appears."
                alert.runModal()
                waitForDriverDevice()
            } catch {
                showError(error)
            }
        }
    }

    private func waitForDriverDevice() {
        Task { @MainActor [weak self] in
            for _ in 0..<10 {
                if DriverManager.device != nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.reconcile()
        }
    }

    private func uninstallDriver() {
        let alert = NSAlert()
        alert.messageText = "Uninstall the Cacophony driver?"
        alert.informativeText = "The Cacophony output device will disappear. System audio returns to the previous output device."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await DriverManager.uninstall()
                reconcile()
            } catch {
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        alog("error: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "Cacophony"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func togglePanel() {
        alog("toggle panel visible=\(panel?.isVisible == true)")
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let panel else { return }
        if !panel.isVisible {
            panelView.resetPicker()
        }
        refreshSpeakerPanel(devices: CACContextOutputDevices(controller.context), force: true)
        guard !panel.isVisible else { return }

        let size = panelView.fittedSize()
        panel.setContentSize(size)
        positionPanel(under: button)
        panel.makeKeyAndOrderFront(nil)
        installClickMonitors()
        alog("panel size \(Int(size.width))x\(Int(size.height))")
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickMonitors()
    }

    private func positionPanel(under button: NSStatusBarButton) {
        guard let panel, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(
            x: buttonRect.midX - panel.frame.width / 2,
            y: buttonRect.minY - panel.frame.height - 6
        )
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }

    private func installClickMonitors() {
        removeClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOutsideClick()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.panel?.isVisible == true, !self.pickerIsPresentingRoutes else {
                return event
            }
            if self.isStatusItemClick(event) { return event }
            guard let eventWindow = event.window else { return event }
            if eventWindow === self.panel { return event }
            self.hidePanel()
            return event
        }
    }

    private func handleOutsideClick() {
        guard !pickerIsPresentingRoutes else { return }
        guard !isStatusItemPoint(NSEvent.mouseLocation) else { return }
        hidePanel()
    }

    private func isStatusItemClick(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        if event.window === window { return true }
        return isStatusItemPoint(NSEvent.mouseLocation)
    }

    private func isStatusItemPoint(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let rect = window
            .convertToScreen(button.convert(button.bounds, to: nil))
            .insetBy(dx: -4, dy: -4)
        return rect.contains(point)
    }

    private func removeClickMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func refreshSpeakerPanel(devices: [NSObject], force: Bool) {
        guard panelView.updateSpeakers(devices, force: force) else { return }
        panelView.resizeKeepingTop()
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            alog("launch at login: \(SMAppService.mainApp.status == .enabled)")
        } catch {
            alog("launch at login failed: \(error)")
        }
        refreshUI()
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        pickerIsPresentingRoutes = true
        alog("speaker list opened")
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        pickerIsPresentingRoutes = false
        lastPickerDismissedAt = ProcessInfo.processInfo.systemUptime
        alog("speaker list dismissed")
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.panelView.resetPicker()
            self.refreshSpeakerPanel(
                devices: CACContextOutputDevices(self.controller.context),
                force: true
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hidePanel()
        DriverManager.restorePreviousOutputIfNeeded()
        controller.stop()
    }
}

@MainActor
func runGUI() -> Never {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.stonerl.Cacophony"
    let otherInstances = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != getpid() }
    if let other = otherInstances.first {
        other.activate()
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    exit(0)
}
