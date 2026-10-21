import CacophonyRouting
import AppKit
import AVKit

@MainActor
final class PointerButton: NSButton {
    var shouldSuppressClick: (() -> Bool)?
    private var suppressClick = false

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        suppressClick = shouldSuppressClick?() ?? false
        super.mouseDown(with: event)
    }

    func consumeSuppressedClick() -> Bool {
        defer { suppressClick = false }
        return suppressClick
    }
}

@MainActor
final class PanelView: NSObject {
    private static let chooseSpeakersTitle = "Choose one or more speakers."

    let panel: StatusPanel
    private let picker: AVRoutePickerView
    private let captionButton: PointerButton
    private let loginCheckbox: NSButton
    private let driverButton: NSButton

    private let rows = NSStackView()
    private let stack = NSStackView()
    private var speakerControls: [SpeakerVolumeControl] = []
    private var lastSpeakerNames: [String] = []

    var canOpenPicker: (() -> Bool)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onDriverAction: (() -> Void)?
    var onQuit: (() -> Void)?

    init(pickerDelegate: AVRoutePickerViewDelegate, contextID: String?) {
        panel = StatusPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: PanelMetrics.contentWidth, height: 220
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        picker = AVRoutePickerView(frame: .zero)
        captionButton = PointerButton(title: PanelView.chooseSpeakersTitle, target: nil, action: nil)
        loginCheckbox = NSButton(
            checkboxWithTitle: "Launch at Login",
            target: nil,
            action: nil
        )
        driverButton = NSButton(title: "Install Driver…", target: nil, action: nil)
        super.init()

        configurePanel()
        configurePicker(contextID: contextID, delegate: pickerDelegate)
        buildLayout()
    }

    func updateCaption(hasSpeakers: Bool, isDefault: Bool) {
        if !hasSpeakers {
            captionButton.title = PanelView.chooseSpeakersTitle
        } else if isDefault {
            captionButton.title = "Cacophony is the system output."
        } else {
            captionButton.title = "Cacophony is not the system output."
        }
    }

    func updateDriverTitle(_ title: String) {
        driverButton.title = title
    }

    func updateLoginState(_ enabled: Bool) {
        loginCheckbox.state = enabled ? .on : .off
    }

    @discardableResult
    func updateSpeakers(_ devices: [NSObject], force: Bool) -> Bool {
        let entries = devices.map { device in
            (
                device: device,
                name: CACDeviceProperty(device, "deviceName") as? String ?? "AirPlay",
                id: CACDeviceProperty(device, "deviceID") as? String ?? ""
            )
        }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }

        let names = entries.map(\.name)
        if !force, names == lastSpeakerNames { return false }
        lastSpeakerNames = names

        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        speakerControls.removeAll()

        guard !entries.isEmpty else {
            let empty = NSTextField(labelWithString: "No speakers selected")
            empty.textColor = .secondaryLabelColor
            rows.addArrangedSubview(empty)
            return true
        }

        for entry in entries {
            let row = makeSpeakerRow(device: entry.device, name: entry.name)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        return true
    }

    private func makeSpeakerRow(device: NSObject, name: String) -> NSView {
        let raw = CACDeviceProperty(device, "volume") ?? CACDeviceProperty(device, "deviceVolume")
        var initial = (raw as? NSNumber)?.doubleValue ?? 0.5
        if initial > 1 {
            initial /= 100
        }
        initial = min(max(initial, 0), 1)

        let icon = NSImageView()
        icon.image = speakerIcon(for: device, name: name)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: name)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let slider = NSSlider(value: initial, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        speakerControls.append(SpeakerVolumeControl(device: device, name: name, slider: slider))

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        row.addSubview(label)
        row.addSubview(slider)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 20),

            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -8),

            slider.widthAnchor.constraint(equalToConstant: 75),
            slider.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            slider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    private func speakerIcon(for device: NSObject, name: String) -> NSImage? {
        let model = CACDeviceProperty(device, "modelID") as? String ?? ""
        let route = CACDeviceProperty(device, "routeSymbolName") as? String
        let base = speakerSymbol(model: model, route: route)
        let symbol = NSImage(systemSymbolName: "\(base).fill", accessibilityDescription: name) != nil
            ? "\(base).fill"
            : base
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        alog("speaker icon \(name): model=\(model) symbol=\(symbol)")
        let configured = image?.withSymbolConfiguration(configuration)
        configured?.isTemplate = true
        return configured
    }

    private func speakerSymbol(model: String, route: String?) -> String {
        if model.hasPrefix("AudioAccessory5,") { return "homepod.mini" }
        if model.hasPrefix("AudioAccessory") { return "homepod" }
        if model.hasPrefix("TimeCapsule") { return "airport.extreme" }
        if model.hasPrefix("AirPort4,") { return "airport.express" }
        if model.hasPrefix("AirPort") { return "airport.extreme" }
        if model.hasPrefix("AppleTV") { return "appletv" }
        if let route, !route.isEmpty { return route }
        return "airplayaudio"
    }

    func fittedSize() -> NSSize {
        panel.contentView?.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        let height = min(
            max(
                stack.fittingSize.height + PanelMetrics.verticalPadding,
                PanelMetrics.minimumHeight
            ),
            PanelMetrics.maximumHeight
        )
        return NSSize(width: PanelMetrics.contentWidth, height: height)
    }

    func resizeKeepingTop() {
        guard panel.isVisible else { return }
        let size = fittedSize()
        guard panel.frame.size != size else { return }
        let top = panel.frame.maxY
        panel.setFrame(
            NSRect(
                x: panel.frame.minX,
                y: top - size.height,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        alog("panel resized to \(Int(size.width))x\(Int(size.height))")
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
    }

    private func configurePicker(contextID: String?, delegate: AVRoutePickerViewDelegate) {
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.isRoutePickerButtonBordered = false
        picker.delegate = delegate
        picker.widthAnchor.constraint(equalToConstant: 24).isActive = true
        picker.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if let contextID {
            let attached = CACPickerSetOutputContextID(picker, contextID)
            alog("picker attached to context: \(attached)")
        }

        captionButton.isBordered = false
        captionButton.setButtonType(.momentaryPushIn)
        captionButton.alignment = .left
        captionButton.contentTintColor = .labelColor
        captionButton.focusRingType = .none
        captionButton.cell?.lineBreakMode = .byTruncatingTail
        captionButton.target = self
        captionButton.action = #selector(openPicker)
        captionButton.toolTip = "Choose speakers"
        captionButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionButton.shouldSuppressClick = { [weak self] in
            guard let self else { return false }
            return !(self.canOpenPicker?() ?? true)
        }

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLaunchAtLogin)

        driverButton.target = self
        driverButton.action = #selector(runDriverAction)
        driverButton.bezelStyle = .glass
        driverButton.controlSize = .small
    }

    private func buildLayout() {
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: PanelMetrics.contentWidth, height: 220)
        )
        container.wantsLayer = true
        container.layer?.cornerRadius = PanelMetrics.cornerRadius
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        let glass = NSGlassEffectView(frame: container.bounds)
        glass.style = .regular
        glass.cornerRadius = PanelMetrics.cornerRadius
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        let content = NSView(frame: glass.bounds)
        content.autoresizingMask = [.width, .height]
        glass.contentView = content

        let pickerRow = NSStackView(views: [picker, captionButton])
        pickerRow.orientation = .horizontal
        pickerRow.spacing = 10
        pickerRow.alignment = .centerY
        pickerRow.translatesAutoresizingMaskIntoConstraints = false

        let separator1 = NSBox()
        separator1.boxType = .separator
        separator1.translatesAutoresizingMaskIntoConstraints = false

        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false

        let quitButton = NSButton(title: "Quit Cacophony", target: nil, action: nil)
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        quitButton.bezelStyle = .glass
        quitButton.controlSize = .small

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [driverButton, bottomSpacer, quitButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(pickerRow)
        stack.addArrangedSubview(separator1)
        stack.addArrangedSubview(rows)
        stack.addArrangedSubview(separator2)
        stack.addArrangedSubview(loginCheckbox)
        stack.addArrangedSubview(bottomRow)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let padding = PanelMetrics.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -padding),
            pickerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator1.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator2.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func openPicker() {
        guard !captionButton.consumeSuppressedClick(),
              canOpenPicker?() ?? true
        else { return }

        if let button = picker.subviews.compactMap({ $0 as? NSButton }).first {
            button.performClick(nil)
        } else {
            let opened = picker.accessibilityPerformPress()
            alog("caption open picker fallback: \(opened)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        onToggleLaunchAtLogin?()
    }

    @objc private func runDriverAction() {
        onDriverAction?()
    }

    @objc private func quitApp() {
        onQuit?()
    }
}
