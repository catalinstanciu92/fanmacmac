import Foundation
import Security
import ServiceManagement

@objc public protocol FanMacPrivilegedHelperProtocol {
    func ping(reply: @escaping (NSNumber) -> Void)
    func apply(targets: [NSNumber], reply: @escaping (NSString?) -> Void)
    func releaseSystemControl(reply: @escaping (NSString?) -> Void)
}

public enum PrivilegedHelperError: LocalizedError {
    case unavailable
    case timedOut
    case authorizationCancelled
    case authorizationFailed(OSStatus)
    case installationFailed(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The privileged helper is not available."
        case .timedOut:
            return "The privileged fan helper did not respond."
        case .authorizationCancelled:
            return "Administrator authorization was cancelled."
        case let .authorizationFailed(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Administrator authorization failed: \(message)"
        case let .installationFailed(message), let .failed(message):
            return message
        }
    }
}

public final class PrivilegedFanController {
    public static let helperLabel = "com.fanmac.helper"
    public static let protocolVersion = 3

    private var controlConnection: NSXPCConnection?

    public init() {}

    deinit {
        controlConnection?.invalidate()
    }

    public func ensureInstalled() throws {
        if isAvailable() { return }
        try PrivilegedHelperInstaller().install()

        for _ in 0..<20 {
            if isAvailable() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw PrivilegedHelperError.unavailable
    }

    public func isAvailable() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let connection = makeConnection()
        var valid = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            semaphore.signal()
        } as? FanMacPrivilegedHelperProtocol

        guard let proxy else {
            connection.invalidate()
            return false
        }
        proxy.ping { version in
            valid = version.intValue == Self.protocolVersion
            semaphore.signal()
        }
        let completed = semaphore.wait(timeout: .now() + 0.75) == .success
        connection.invalidate()
        return completed && valid
    }

    public func apply(targets: [Int]) throws {
        try call { proxy, reply in
            proxy.apply(targets: targets.map(NSNumber.init), reply: reply)
        }
    }

    public func releaseSystemControl() throws {
        try call { proxy, reply in
            proxy.releaseSystemControl(reply: reply)
        }
    }

    private func call(
        _ operation: (FanMacPrivilegedHelperProtocol, @escaping (NSString?) -> Void) -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let connection = persistentControlConnection()
        var failure: String?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure = error.localizedDescription
            semaphore.signal()
        } as? FanMacPrivilegedHelperProtocol

        guard let proxy else {
            resetControlConnection(connection)
            throw PrivilegedHelperError.unavailable
        }
        operation(proxy) { error in
            failure = error as String?
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 12) == .success else {
            resetControlConnection(connection)
            throw PrivilegedHelperError.timedOut
        }
        if let failure {
            resetControlConnection(connection)
            throw PrivilegedHelperError.failed(failure)
        }
    }

    private func persistentControlConnection() -> NSXPCConnection {
        if let controlConnection { return controlConnection }
        let connection = makeConnection()
        controlConnection = connection
        return connection
    }

    private func resetControlConnection(_ connection: NSXPCConnection) {
        if controlConnection === connection {
            controlConnection = nil
        }
        connection.invalidate()
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: Self.helperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanMacPrivilegedHelperProtocol.self)
        connection.resume()
        return connection
    }
}

public final class PrivilegedHelperInstaller {
    public init() {}

    public func install() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw PrivilegedHelperError.installationFailed(
                "FanMac must be launched from FanMac.app to install its helper."
            )
        }

        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw PrivilegedHelperError.authorizationFailed(createStatus)
        }
        defer { AuthorizationFree(authorization, []) }

        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let rightStatus = kSMRightBlessPrivilegedHelper.withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(authorization, &rights, nil, flags, nil)
            }
        }
        if rightStatus == errAuthorizationCanceled {
            throw PrivilegedHelperError.authorizationCancelled
        }
        guard rightStatus == errAuthorizationSuccess else {
            throw PrivilegedHelperError.authorizationFailed(rightStatus)
        }

        var unmanagedError: Unmanaged<CFError>?
        let installed = SMJobBless(
            kSMDomainSystemLaunchd,
            PrivilegedFanController.helperLabel as CFString,
            authorization,
            &unmanagedError
        )
        guard installed else {
            let error = unmanagedError?.takeRetainedValue()
            throw PrivilegedHelperError.installationFailed(
                error?.localizedDescription ?? "macOS could not install the privileged helper."
            )
        }
    }
}
