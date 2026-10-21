import CacophonyHelperProtocol
import Darwin
import Foundation

private let serviceName = CacophonyHelperConstants.machServiceName
private let driverName = CacophonyHelperConstants.driverName
private let halDirectory = CacophonyHelperConstants.halDirectoryPath

private enum HelperError: LocalizedError {
    case bundlePathUnavailable
    case driverMissing(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundlePathUnavailable:
            return "Could not locate the Cacophony app bundle."
        case .driverMissing(let path):
            return "The bundled driver is missing at \(path)."
        case .commandFailed(let message):
            return message
        }
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("CacophonyHelper: \(message)\n".utf8))
}

private func executableURL() throws -> URL {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        throw HelperError.bundlePathUnavailable
    }
    let path = buffer.withUnsafeBufferPointer { pointer -> String in
        let length = pointer.firstIndex(of: 0) ?? pointer.count
        return String(decoding: pointer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
}

private func driverSourceURL() throws -> URL {
    let appURL = try executableURL()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = appURL.appendingPathComponent("Contents/Resources/\(driverName)")
    guard FileManager.default.fileExists(atPath: source.path) else {
        throw HelperError.driverMissing(source.path)
    }
    return source
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        log("failed to run \(executable): \(error.localizedDescription)")
        return -1
    }
}

private func setOwnership(_ url: URL) throws {
    let status = run("/usr/sbin/chown", ["-R", "root:wheel", url.path])
    guard status == 0 else {
        throw HelperError.commandFailed("Could not set driver ownership.")
    }
}

private func restartCoreAudio() {
    let status = run("/usr/bin/killall", ["-TERM", "coreaudiod"])
    if status != 0 {
        log("coreaudiod restart failed: \(status)")
    }
}

private func performInstall() throws {
    let source = try driverSourceURL()
    let halURL = URL(fileURLWithPath: halDirectory, isDirectory: true)
    let destination = halURL.appendingPathComponent(driverName)
    let staging = halURL.appendingPathComponent(".\(driverName).new")

    let fileManager = FileManager.default
    try fileManager.createDirectory(at: halURL, withIntermediateDirectories: true)

    if fileManager.fileExists(atPath: staging.path) {
        try fileManager.removeItem(at: staging)
    }
    try fileManager.copyItem(at: source, to: staging)

    do {
        try setOwnership(staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    } catch {
        try? fileManager.removeItem(at: staging)
        throw error
    }

    restartCoreAudio()
}

private func performUninstall() throws {
    let destination = URL(fileURLWithPath: halDirectory, isDirectory: true)
        .appendingPathComponent(driverName)
    let fileManager = FileManager.default

    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    restartCoreAudio()
}

private final class HelperService: NSObject, CacophonyHelperProtocol {
    func installDriver(withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try performInstall()
            log("installed driver")
            reply(true, nil)
        } catch {
            log("install failed: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }

    func uninstallDriver(withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try performUninstall()
            log("uninstalled driver")
            reply(true, nil)
        } catch {
            log("uninstall failed: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }
}

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: CacophonyHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: serviceName)
private let delegate = ServiceDelegate()
listener.delegate = delegate

#if DEBUG
let callerRequirement = "identifier \"com.stonerl.Cacophony\""
#else
let callerRequirement =
    "identifier \"com.stonerl.Cacophony\" and anchor apple generic and certificate leaf[subject.OU] = \"456BPWQ6U5\""
#endif

listener.setConnectionCodeSigningRequirement(callerRequirement)
listener.resume()
log("listening on \(serviceName)")
RunLoop.current.run()
