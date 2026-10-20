import CacophonyRouting
import AppKit

@MainActor
final class SpeakerVolumeControl: NSObject {
    private let device: NSObject
    private let name: String
    private let slider: NSSlider

    init(device: NSObject, name: String, slider: NSSlider) {
        self.device = device
        self.name = name
        self.slider = slider
        super.init()
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        let ok = CACDeviceSetVolume(device, Float(value))
        alog("speaker volume \(name): \(String(format: "%.2f", value)) ok=\(ok)")
    }
}
