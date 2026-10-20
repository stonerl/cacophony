import CoreAudio
import Foundation

enum DriverManagerError: LocalizedError {
    case driverDeviceMissing
    case bundledDriverMissing
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .driverDeviceMissing: return "The Cacophony audio device is not available. Reinstall the driver and restart coreaudiod."
        case .bundledDriverMissing: return "The bundled Cacophony driver could not be found."
        case .commandFailed(let message): return message
        }
    }
}

enum DriverManager {
    static let deviceUID = "CacophonyDevice"
    static let driverName = "CacophonyDriver.driver"
    private static let halDirectoryURL = URL(
        fileURLWithPath: "/Library/Audio/Plug-Ins/HAL",
        isDirectory: true
    )
    private static let restartCoreAudioCommand =
        "launchctl kickstart -k system/com.apple.audio.coreaudiod || killall -9 coreaudiod || true"

    static var installedDriverURL: URL {
        halDirectoryURL.appendingPathComponent(driverName)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedDriverURL.path)
    }

    static var device: AudioObjectID? {
        guard let devices = try? AudioObjectID.allDevices() else { return nil }
        return devices.first { (try? $0.readString(kAudioDevicePropertyDeviceUID)) == deviceUID }
    }

    static var isDefaultOutput: Bool {
        guard let current = try? AudioObjectID.defaultOutputDevice(),
              let uid = try? current.readString(kAudioDevicePropertyDeviceUID)
        else { return false }
        return uid == deviceUID
    }

    private static func shortVersion(at bundleURL: URL) -> String? {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    static var installedVersion: String? {
        shortVersion(at: installedDriverURL)
    }

    static var bundledDriverURL: URL? {
        Bundle.main.url(forResource: "CacophonyDriver", withExtension: "driver")
    }

    static var bundledVersion: String? {
        guard let bundledDriverURL else { return nil }
        return shortVersion(at: bundledDriverURL)
    }

    static var isUpdateAvailable: Bool {
        guard isInstalled, let bundledVersion else { return false }
        guard let installedVersion else { return true }
        return bundledVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }

    static var currentOutputUID: String? {
        guard let current = try? AudioObjectID.defaultOutputDevice() else { return nil }
        return try? current.readString(kAudioDevicePropertyDeviceUID)
    }

    static func setAsDefaultOutput() throws {
        guard let device else { throw DriverManagerError.driverDeviceMissing }
        noteDefaultOutputChange()
        try AudioObjectID.setDefaultOutputDevice(device)
    }

    /// Remembers the last non-Cacophony system output so it can be restored
    /// when the helper quits or is uninstalled.
    static func noteDefaultOutputChange() {
        guard let uid = currentOutputUID, uid != deviceUID else { return }
        UserDefaults.standard.set(uid, forKey: "previousOutputUID")
    }

    static func restorePreviousOutputIfNeeded() {
        guard isDefaultOutput else { return }

        let devices = (try? AudioObjectID.allDevices()) ?? []
        var target: AudioObjectID?

        if let uid = UserDefaults.standard.string(forKey: "previousOutputUID") {
            target = devices.first { (try? $0.readString(kAudioDevicePropertyDeviceUID)) == uid }
        }
        if target == nil {
            target = devices.first { (try? $0.readString(kAudioDevicePropertyDeviceUID)) == "BuiltInSpeakerDevice" }
        }

        guard let target else { return }
        try? AudioObjectID.setDefaultOutputDevice(target)
        UserDefaults.standard.removeObject(forKey: "previousOutputUID")
    }

    static func install() throws {
        guard let driver = bundledDriverURL else {
            throw DriverManagerError.bundledDriverMissing
        }
        let destination = shellQuote(installedDriverURL.path)
        let halDirectory = shellQuote(halDirectoryURL.path)
        let command = """
        set -e
        rm -rf \(destination)
        cp -R \(shellQuote(driver.path)) \(halDirectory)/
        chown -R root:wheel \(destination)
        \(restartCoreAudioCommand)
        """
        try runAsAdministrator(command)
    }

    static func uninstall() throws {
        let command = """
        set -e
        rm -rf \(shellQuote(installedDriverURL.path))
        \(restartCoreAudioCommand)
        """
        try runAsAdministrator(command)
    }

    private static func runAsAdministrator(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DriverManagerError.commandFailed(
                message.flatMap { $0.isEmpty ? nil : $0 } ?? "Installer failed."
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
