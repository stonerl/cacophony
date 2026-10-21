import CacophonyHelperProtocol
import Foundation
import ServiceManagement

enum PrivilegedHelperError: LocalizedError {
    case helperUnavailable
    case approvalRequired
    case connectionFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "The Cacophony helper is unavailable. Reinstall Cacophony."
        case .approvalRequired:
            return "Cacophony needs permission to install its driver. Allow Cacophony in System Settings > General > Login Items & Extensions, then try again. Installation can continue automatically after approval."
        case .connectionFailed(let message):
            return "Could not connect to the Cacophony helper: \(message)"
        case .operationFailed(let message):
            return message
        }
    }
}

enum PrivilegedHelper {
    private static let plistName = CacophonyHelperConstants.launchDaemonPlistName

    private static var service: SMAppService {
        .daemon(plistName: plistName)
    }

    static func install() async throws {
        try await waitForApproval()
        try await call { proxy, reply in
            proxy.installDriver(withReply: reply)
        }
    }

    static func uninstall() async throws {
        try await waitForApproval()
        try await call { proxy, reply in
            proxy.uninstallDriver(withReply: reply)
        }
        try? await service.unregister()
    }

    private static func waitForApproval() async throws {
        let deadline = Date().addingTimeInterval(120)
        var openedSettings = false
        var lastRegistrationAttempt = Date.distantPast

        while Date() < deadline {
            let status = service.status
            alog("helper status: \(status.rawValue)")

            switch status {
            case .enabled:
                return
            case .requiresApproval:
                if !openedSettings {
                    SMAppService.openSystemSettingsLoginItems()
                    openedSettings = true
                }
            case .notRegistered, .notFound:
                if Date().timeIntervalSince(lastRegistrationAttempt) >= 2 {
                    lastRegistrationAttempt = Date()
                    do {
                        try service.register()
                    } catch {
                        alog("helper registration: \(error.localizedDescription)")
                    }
                }
            @unknown default:
                throw PrivilegedHelperError.helperUnavailable
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        throw PrivilegedHelperError.approvalRequired
    }

    private static func call(
        _ operation: @escaping (CacophonyHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: CacophonyHelperConstants.machServiceName)
            let gate = ContinuationGate(continuation)

            connection.remoteObjectInterface = NSXPCInterface(with: CacophonyHelperProtocol.self)
            connection.interruptionHandler = {
                gate.resume(throwing: PrivilegedHelperError.connectionFailed("interrupted"))
            }
            connection.invalidationHandler = {
                gate.resume(throwing: PrivilegedHelperError.connectionFailed("invalidated"))
            }
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.resume(throwing: PrivilegedHelperError.connectionFailed(error.localizedDescription))
            }) as? CacophonyHelperProtocol else {
                connection.invalidate()
                gate.resume(throwing: PrivilegedHelperError.connectionFailed("invalid proxy"))
                return
            }

            operation(proxy) { success, message in
                connection.invalidate()
                if success {
                    gate.resume()
                } else {
                    gate.resume(throwing: PrivilegedHelperError.operationFailed(
                        message ?? "The helper operation failed."
                    ))
                }
            }
        }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        finish { continuation.resume() }
    }

    func resume(throwing error: Error) {
        finish { continuation.resume(throwing: error) }
    }

    private func finish(_ action: () -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        action()
    }
}
