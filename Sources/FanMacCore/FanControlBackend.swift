import Foundation

public enum HardwareStatus: Equatable, Sendable {
    case connected
    case noFans
    case unavailable(String)

    public var title: String {
        switch self {
        case .connected: return "Connected"
        case .noFans: return "No fan controller"
        case .unavailable: return "Hardware unavailable"
        }
    }
}

public struct FanReading: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let minimumRPM: Double
    public let currentRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double?
    public let controlMode: UInt8?

    public init(
        id: Int,
        name: String,
        minimumRPM: Double,
        currentRPM: Double,
        maximumRPM: Double,
        targetRPM: Double? = nil,
        controlMode: UInt8? = nil
    ) {
        self.id = id
        self.name = name
        self.minimumRPM = minimumRPM
        self.currentRPM = currentRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
        self.controlMode = controlMode
    }

    public var currentPercent: Double {
        guard maximumRPM > 0 else { return 0 }
        return min(max(currentRPM / maximumRPM, 0), 1)
    }

    public var isManualMode: Bool { controlMode == 1 }
}

public struct HardwareSnapshot: Sendable {
    public let temperatureCelsius: Double?
    public let fans: [FanReading]
    public let status: HardwareStatus
    public let message: String?

    public init(
        temperatureCelsius: Double?,
        fans: [FanReading],
        status: HardwareStatus,
        message: String? = nil
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.fans = fans
        self.status = status
        self.message = message
    }
}

public protocol FanControlBackend: AnyObject {
    func snapshot() -> HardwareSnapshot
    func prepareForControl() throws
    func apply(targetRPMs: [Int]) throws
    func releaseSystemControl() throws
}

public enum FanControlError: LocalizedError {
    case manualModeUnavailable(Int)
    case fanLimitsUnavailable(Int)
    case releaseCouldNotBeVerified([Int])
    case applyFailedAndReleaseUnverified(String, String)

    public var errorDescription: String? {
        switch self {
        case let .manualModeUnavailable(fan):
            return "Fan \(fan + 1) did not enter manual mode."
        case let .fanLimitsUnavailable(fan):
            return "Safe RPM limits are unavailable for fan \(fan + 1); no target was written."
        case let .releaseCouldNotBeVerified(fans):
            let names = fans.map { String($0 + 1) }.joined(separator: ", ")
            return "Fan mode remained manual for fan(s) \(names)."
        case let .applyFailedAndReleaseUnverified(applyError, releaseError):
            return "Fan update failed (\(applyError)) and automatic control could not be verified (\(releaseError))."
        }
    }
}

public final class SMCFanBackend: FanControlBackend {
    private let smc: SMCClient
    private let cpuAverageKeys: [String]
    private let privilegedHelper: PrivilegedFanController?

    private let cpuAverageCandidates = [
        "TCMb", // CPU die core max / average-like aggregate on some Apple Silicon firmware.
        "TC0C", // CPU die core aggregate on some systems.
        "TC0D", // CPU die temperature on systems exposing the diode.
        "TCGC", // CPU PECI core aggregate on some SMC revisions.
        "TC0P"  // CPU proximity fallback for older firmware.
    ]

    public init(usePrivilegedHelper: Bool = true) throws {
        let client = try SMCClient()
        smc = client
        cpuAverageKeys = Self.discoverCPUAverageKeys(using: client, fallback: cpuAverageCandidates)
        privilegedHelper = usePrivilegedHelper ? PrivilegedFanController() : nil
    }

    public func prepareForControl() throws {
        try privilegedHelper?.ensureInstalled()
    }

    public func snapshot() -> HardwareSnapshot {
        let temperature = readCPUCoreAverage()
        let fanCount = readUInt8("FNum") ?? 0
        let fans = (0..<Int(fanCount)).compactMap(readFan)

        if fans.isEmpty {
            return HardwareSnapshot(
                temperatureCelsius: temperature,
                fans: [],
                status: .noFans,
                message: "This Mac does not expose a controllable fan through AppleSMC."
            )
        }
        if temperature == nil {
            return HardwareSnapshot(
                temperatureCelsius: nil,
                fans: fans,
                status: .unavailable("CPU Core Average sensor is not available."),
                message: "The CPU Core Average sensor could not be read."
            )
        }
        return HardwareSnapshot(temperatureCelsius: temperature, fans: fans, status: .connected)
    }

    public func apply(targetRPMs: [Int]) throws {
        guard !targetRPMs.isEmpty else { return }
        if let privilegedHelper {
            try privilegedHelper.apply(targets: targetRPMs)
        } else {
            try applyDirect(targetRPMs: targetRPMs)
        }
    }

    public func releaseSystemControl() throws {
        if let privilegedHelper {
            try privilegedHelper.ensureInstalled()
            try privilegedHelper.releaseSystemControl()
        } else {
            try releaseDirectControl()
        }
    }

    private func applyDirect(targetRPMs: [Int]) throws {
        // Apple Silicon firmware keeps thermal management in system mode by default.
        // Ftst is present on many generations and hands fan mode to a privileged client.
        // If the key is not present, the mode write below is still attempted.
        do {
            try? smc.writeUInt8("Ftst", 1)

            for (index, target) in targetRPMs.enumerated() {
                guard let minimumRPM = readNumeric(String(format: "F%dMn", index)),
                      let maximumRPM = readNumeric(String(format: "F%dMx", index)),
                      let safeTarget = FanCurve.safeManualRPM(
                          requestedRPM: Double(target),
                          minimumRPM: minimumRPM,
                          maximumRPM: maximumRPM
                      ) else {
                    throw FanControlError.fanLimitsUnavailable(index)
                }

                let modeKey = try preferredModeKey(for: index)
                var enteredManualMode = false
                for attempt in 0..<16 {
                    do {
                        try smc.writeUInt8(modeKey, 1)
                        if readUInt8(modeKey) == 1 {
                            enteredManualMode = true
                            break
                        }
                    } catch {
                        // M3/M4 firmware can reject mode writes for several seconds
                        // while Ftst hands control over from thermalmonitord.
                    }
                    if attempt < 15 {
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                }
                guard enteredManualMode else { throw FanControlError.manualModeUnavailable(index) }
                try smc.writeFloat(String(format: "F%dTg", index), safeTarget)
            }
        } catch {
            do {
                try releaseDirectControl()
            } catch let releaseError {
                throw FanControlError.applyFailedAndReleaseUnverified(
                    error.localizedDescription,
                    releaseError.localizedDescription
                )
            }
            throw error
        }
    }

    private func releaseDirectControl() throws {
        let fanCount = Int(readUInt8("FNum") ?? 0)
        for index in 0..<fanCount {
            if let key = try? preferredModeKey(for: index) {
                try? smc.writeUInt8(key, 0)
            }
        }
        // Ftst must be cleared after leaving manual mode so thermalmonitord owns
        // the fans again. It is absent on some generations, so absence is benign.
        try? smc.writeUInt8("Ftst", 0)

        for attempt in 0..<12 {
            let unverifiedFans = (0..<fanCount).filter { index in
                guard let key = try? preferredModeKey(for: index),
                      let mode = readUInt8(key) else { return true }
                return mode == 1
            }
            if unverifiedFans.isEmpty { return }
            if attempt < 11 {
                Thread.sleep(forTimeInterval: 0.25)
            } else {
                throw FanControlError.releaseCouldNotBeVerified(unverifiedFans)
            }
        }
    }

    private func readCPUCoreAverage() -> Double? {
        let values = cpuAverageKeys.compactMap { readNumeric($0) }
            .filter { $0.isFinite && (0...130).contains($0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func readFan(index: Int) -> FanReading? {
        let current = readNumeric(String(format: "F%dAc", index))
        let minimum = readNumeric(String(format: "F%dMn", index))
        let maximum = readNumeric(String(format: "F%dMx", index))
        guard let current, let minimum, let maximum, maximum > 0 else { return nil }
        return FanReading(
            id: index,
            name: "Fan \(index + 1)",
            minimumRPM: minimum,
            currentRPM: current,
            maximumRPM: maximum,
            targetRPM: readNumeric(String(format: "F%dTg", index)),
            controlMode: readFanMode(index: index)
        )
    }

    private func readNumeric(_ key: String) -> Double? {
        try? smc.read(key).numericValue
    }

    private func readUInt8(_ key: String) -> UInt8? {
        guard let value = try? smc.read(key).unsignedInteger else { return nil }
        return UInt8(clamping: value)
    }

    private func readFanMode(index: Int) -> UInt8? {
        guard let key = try? preferredModeKey(for: index) else { return nil }
        return readUInt8(key)
    }

    private func preferredModeKey(for index: Int) throws -> String {
        let uppercase = String(format: "F%dMd", index)
        if (try? smc.read(uppercase)) != nil { return uppercase }
        return String(format: "F%dmd", index)
    }

    private static func discoverCPUAverageKeys(using smc: SMCClient, fallback: [String]) -> [String] {
        guard let keyCount = try? smc.keyCount(), keyCount > 0 else { return fallback }

        var discovered: [String] = []
        discovered.reserveCapacity(32)
        for index in 0..<keyCount {
            guard let key = try? smc.key(at: index) else { continue }
            let bytes = Array(key.utf8)
            guard bytes.count == 4,
                  bytes[0] == 84,
                  [112, 101, 115].contains(bytes[1]),
                  let value = try? smc.read(key),
                  value.dataType == "sp78" || value.dataType == "flt " else { continue }
            discovered.append(key)
        }
        return discovered.isEmpty ? fallback : discovered
    }
}

public final class UnavailableFanBackend: FanControlBackend {
    private let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func snapshot() -> HardwareSnapshot {
        HardwareSnapshot(temperatureCelsius: nil, fans: [], status: .unavailable(reason), message: reason)
    }

    public func prepareForControl() throws {
        throw SMCClientError.openFailed(-1)
    }

    public func apply(targetRPMs: [Int]) throws {
        throw SMCClientError.openFailed(-1)
    }

    public func releaseSystemControl() throws {}
}
