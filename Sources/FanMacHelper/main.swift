import FanMacCore
import Foundation
import Security

final class FanControlManager {
    private let backend: SMCFanBackend?
    private let lock = NSLock()

    init() {
        backend = try? SMCFanBackend(usePrivilegedHelper: false)
    }

    func apply(targets: [Int]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let backend else {
            throw PrivilegedHelperError.failed("AppleSMC could not be opened by the helper.")
        }
        try backend.apply(targetRPMs: targets)
    }

    func releaseSystemControl() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let backend else {
            throw PrivilegedHelperError.failed("AppleSMC could not be opened by the helper.")
        }
        try backend.releaseSystemControl()
    }
}

final class FanMacHelperService: NSObject, FanMacPrivilegedHelperProtocol {
    private let manager: FanControlManager
    private let leaseLock = NSLock()
    private var ownsControlLease = false

    init(manager: FanControlManager) {
        self.manager = manager
        super.init()
    }

    func ping(reply: @escaping (NSNumber) -> Void) {
        reply(NSNumber(value: PrivilegedFanController.protocolVersion))
    }

    func apply(targets: [NSNumber], reply: @escaping (NSString?) -> Void) {
        setOwnsControlLease(true)
        do {
            try manager.apply(targets: targets.map(\.intValue))
            reply(nil)
        } catch {
            setOwnsControlLease(false)
            reply(error.localizedDescription as NSString)
        }
    }

    func releaseSystemControl(reply: @escaping (NSString?) -> Void) {
        do {
            try manager.releaseSystemControl()
            setOwnsControlLease(false)
            reply(nil)
        } catch {
            reply(error.localizedDescription as NSString)
        }
    }

    func connectionInvalidated() {
        guard takeControlLease() else { return }
        try? manager.releaseSystemControl()
    }

    private func setOwnsControlLease(_ value: Bool) {
        leaseLock.lock()
        ownsControlLease = value
        leaseLock.unlock()
    }

    private func takeControlLease() -> Bool {
        leaseLock.lock()
        defer { leaseLock.unlock() }
        let result = ownsControlLease
        ownsControlLease = false
        return result
    }
}

final class FanMacHelperDelegate: NSObject, NSXPCListenerDelegate {
    private let manager = FanControlManager()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard ConnectionValidator.isFanMac(newConnection) else { return false }
        let service = FanMacHelperService(manager: manager)
        newConnection.exportedInterface = NSXPCInterface(with: FanMacPrivilegedHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak service] in
            service?.connectionInvalidated()
        }
        newConnection.resume()
        return true
    }
}

private enum ConnectionValidator {
    static func isFanMac(_ connection: NSXPCConnection) -> Bool {
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary

        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else { return false }

        var requirement: SecRequirement?
        let requirementText = "identifier \"com.fanmac.app\"" as CFString
        guard SecRequirementCreateWithString(requirementText, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        guard SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess else { return false }

        let expectedTeam = Bundle.main.object(forInfoDictionaryKey: "FanMacTeamIdentifier") as? String
        guard let expectedTeam, expectedTeam != "LOCAL" else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &signingInfo) == errSecSuccess,
              let info = signingInfo as? [CFString: Any],
              let actualTeam = info[kSecCodeInfoTeamIdentifier] as? String else { return false }
        return actualTeam == expectedTeam
    }
}

let listener = NSXPCListener(machServiceName: "com.fanmac.helper")
let delegate = FanMacHelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
