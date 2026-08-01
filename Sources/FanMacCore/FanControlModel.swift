import Combine
import Foundation

@MainActor
public final class FanControlModel: ObservableObject {
    @Published public private(set) var temperatureCelsius: Double?
    @Published public private(set) var temperatureHistory: [Double] = []
    @Published public private(set) var fans: [FanReading] = []
    @Published public private(set) var hardwareStatus: HardwareStatus = .unavailable("Connecting to AppleSMC…")
    @Published public private(set) var hardwareMessage: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var settings: ControlSettings
    @Published public private(set) var isControlEnabled = false
    @Published public private(set) var isChangingControl = false
    @Published public private(set) var isManualModeDetected = false
    @Published public private(set) var isUsingSystemAutomaticControl = true

    private let backend: FanControlBackend
    private var timer: Timer?
    private var lastAppliedTargets: [Int] = []
    private var lastFailedTargets: [Int] = []
    private let settingsKey = "FanMac.ControlSettings"

    public init(backend: FanControlBackend? = nil, settings: ControlSettings? = nil) {
        self.backend = backend ?? Self.makeDefaultBackend()
        self.settings = settings ?? Self.loadSettings()
    }

    public func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        _ = restoreSystemControl(showError: false)
    }

    public func prepareToQuit() -> Bool {
        restoreSystemControl(showError: true)
    }

    public func refresh() {
        let snapshot = backend.snapshot()
        temperatureCelsius = snapshot.temperatureCelsius
        fans = snapshot.fans
        isManualModeDetected = snapshot.fans.contains(where: \.isManualMode)
        if isManualModeDetected {
            isUsingSystemAutomaticControl = false
        } else if lastAppliedTargets.isEmpty {
            isUsingSystemAutomaticControl = true
        }
        hardwareStatus = snapshot.status
        hardwareMessage = snapshot.message

        if let temperatureCelsius {
            temperatureHistory.append(temperatureCelsius)
            if temperatureHistory.count > 36 {
                temperatureHistory.removeFirst(temperatureHistory.count - 36)
            }
        }
        applyCurrentCurveIfPossible()
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isControlEnabled, !isChangingControl else { return }
        lastError = nil
        isChangingControl = true
        defer { isChangingControl = false }

        if enabled {
            enableControl()
        } else {
            _ = restoreSystemControl(showError: true)
        }
    }

    @discardableResult
    public func restoreSystemControl(showError: Bool = true) -> Bool {
        guard isManualModeDetected || !lastAppliedTargets.isEmpty else {
            isControlEnabled = false
            isUsingSystemAutomaticControl = true
            clearTargetState()
            return true
        }

        do {
            try backend.releaseSystemControl()
            isControlEnabled = false
            isUsingSystemAutomaticControl = true
            clearTargetState()
            lastError = nil
            refreshFanTelemetry()
            return true
        } catch {
            // Keep the switch visibly on: manual mode may still be active.
            isControlEnabled = true
            isUsingSystemAutomaticControl = false
            if showError {
                lastError = "Could not restore macOS fan control: \(error.localizedDescription)"
            }
            return false
        }
    }

    public func setMinimumSpeedPercent(_ value: Double) {
        settings.minimumSpeedPercent = min(max(value, 0), 70)
        settingsDidChange()
    }

    public func setRampStartCelsius(_ value: Double) {
        settings.rampStartCelsius = min(max(value, 40), settings.fullSpeedCelsius - 5)
        settingsDidChange()
    }

    public func setFullSpeedCelsius(_ value: Double) {
        settings.fullSpeedCelsius = max(min(value, 105), settings.rampStartCelsius + 5)
        settingsDidChange()
    }

    public var temperatureLabel: String {
        guard let temperatureCelsius else { return "—" }
        return String(format: "%.1f", temperatureCelsius)
    }

    public var menuBarTemperatureLabel: String {
        guard let temperatureCelsius else { return "—°" }
        return String(format: "%.0f°", temperatureCelsius)
    }

    public var curveSummary: String {
        if settings.minimumSpeedPercent <= 0 {
            return "AUTO below \(Int(settings.rampStartCelsius))° · then boost"
        }
        return "\(Int(settings.minimumSpeedPercent))% floor · boost from \(Int(settings.rampStartCelsius))°"
    }

    public var isActivelyControllingFans: Bool {
        !isUsingSystemAutomaticControl && (isControlEnabled || isManualModeDetected)
    }

    public var statusLabel: String {
        if isChangingControl { return "Authorizing fan control…" }
        if !isControlEnabled, isManualModeDetected { return "Manual fan mode detected" }
        if lastError != nil { return isControlEnabled ? "Control needs attention" : "System control" }
        if isControlEnabled, isUsingSystemAutomaticControl { return "Armed · macOS automatic control" }
        if isControlEnabled { return "CPU curve active" }
        return hardwareStatus == .connected ? "System control" : hardwareStatus.title
    }

    private func enableControl() {
        guard hasSafeTelemetry else {
            lastError = hardwareMessage ?? "A compatible CPU sensor and fan are required."
            isControlEnabled = false
            isUsingSystemAutomaticControl = true
            return
        }

        do {
            // This performs the first-use native administrator authorization if needed.
            try backend.prepareForControl()
        } catch {
            isControlEnabled = false
            isUsingSystemAutomaticControl = true
            clearTargetState()
            lastError = error.localizedDescription
            return
        }

        isControlEnabled = true
        if shouldUseSystemAutomaticControl {
            transitionToSystemAutomaticControl()
            return
        }

        let targets = calculatedTargets()
        do {
            try backend.apply(targetRPMs: targets)
            isUsingSystemAutomaticControl = false
            lastAppliedTargets = targets
            lastFailedTargets = []
            lastError = nil
        } catch {
            recoverFromApplyFailure(error, targets: targets)
        }
    }

    private func settingsDidChange() {
        saveSettings()
        lastFailedTargets = []
        applyCurrentCurveIfPossible()
    }

    private func applyCurrentCurveIfPossible() {
        guard isControlEnabled else { return }

        guard hasSafeTelemetry else {
            disableForUnsafeTelemetry()
            return
        }

        if shouldUseSystemAutomaticControl {
            transitionToSystemAutomaticControl()
            return
        }

        let targets = calculatedTargets()
        let manualModeNeedsRecovery = !isManualModeDetected && !lastAppliedTargets.isEmpty
        guard (targets != lastAppliedTargets || manualModeNeedsRecovery),
              targets != lastFailedTargets else { return }

        do {
            try backend.apply(targetRPMs: targets)
            isUsingSystemAutomaticControl = false
            lastAppliedTargets = targets
            lastFailedTargets = []
            lastError = nil
        } catch {
            recoverFromApplyFailure(error, targets: targets)
        }
    }

    private var hasSafeTelemetry: Bool {
        guard hardwareStatus == .connected,
              let temperatureCelsius,
              temperatureCelsius.isFinite,
              !fans.isEmpty else { return false }
        return fans.allSatisfy { fan in
            fan.minimumRPM.isFinite && fan.maximumRPM.isFinite &&
                fan.minimumRPM >= 0 && fan.maximumRPM >= fan.minimumRPM
        }
    }

    private var shouldUseSystemAutomaticControl: Bool {
        guard let temperatureCelsius else { return true }
        return FanCurve.usesSystemAutomaticControl(
            temperatureCelsius: temperatureCelsius,
            settings: settings
        )
    }

    private func transitionToSystemAutomaticControl() {
        guard isManualModeDetected || !lastAppliedTargets.isEmpty else {
            isUsingSystemAutomaticControl = true
            lastFailedTargets = []
            lastError = nil
            return
        }

        do {
            try backend.releaseSystemControl()
            isUsingSystemAutomaticControl = true
            clearTargetState()
            lastError = nil
            refreshFanTelemetry()
        } catch {
            // Keep retrying on future refreshes while the switch remains on.
            isUsingSystemAutomaticControl = false
            lastError = "Could not return the fans to macOS automatic control: \(error.localizedDescription)"
        }
    }

    private func disableForUnsafeTelemetry() {
        let reason = hardwareMessage ?? "CPU or fan safety telemetry became unavailable."
        guard isManualModeDetected || !lastAppliedTargets.isEmpty else {
            isControlEnabled = false
            isUsingSystemAutomaticControl = true
            clearTargetState()
            lastError = "Fan control was disabled: \(reason)"
            return
        }

        do {
            try backend.releaseSystemControl()
            isControlEnabled = false
            isUsingSystemAutomaticControl = true
            clearTargetState()
            lastError = "Fan control was disabled and macOS control was restored: \(reason)"
            refreshFanTelemetry()
        } catch {
            isControlEnabled = true
            isUsingSystemAutomaticControl = false
            lastError = "Safety telemetry was lost and macOS control could not be verified: \(error.localizedDescription)"
        }
    }

    private func recoverFromApplyFailure(_ error: Error, targets: [Int]) {
        lastFailedTargets = targets
        do {
            try backend.releaseSystemControl()
            isControlEnabled = false
            isUsingSystemAutomaticControl = true
            clearTargetState()
            lastError = "Fan update failed; macOS system control was restored. \(error.localizedDescription)"
            refreshFanTelemetry()
        } catch let releaseError {
            isControlEnabled = true
            isUsingSystemAutomaticControl = false
            lastError = "Fan update failed and system control could not be verified: \(releaseError.localizedDescription)"
        }
    }

    private func calculatedTargets() -> [Int] {
        fans.map { fan in
            Int(FanCurve.targetRPM(
                temperatureCelsius: temperatureCelsius ?? 0,
                minimumRPM: fan.minimumRPM,
                maximumRPM: fan.maximumRPM,
                settings: settings
            ).rounded())
        }
    }

    private func clearTargetState() {
        lastAppliedTargets = []
        lastFailedTargets = []
    }

    private func refreshFanTelemetry() {
        let snapshot = backend.snapshot()
        fans = snapshot.fans
        isManualModeDetected = snapshot.fans.contains(where: \.isManualMode)
        hardwareStatus = snapshot.status
        hardwareMessage = snapshot.message
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    private static func loadSettings() -> ControlSettings {
        guard let data = UserDefaults.standard.data(forKey: "FanMac.ControlSettings"),
              let saved = try? JSONDecoder().decode(ControlSettings.self, from: data) else {
            return ControlSettings()
        }
        return saved
    }

    private static func makeDefaultBackend() -> FanControlBackend {
        #if arch(arm64)
        do {
            return try SMCFanBackend()
        } catch {
            return UnavailableFanBackend(reason: error.localizedDescription)
        }
        #else
        return UnavailableFanBackend(reason: "FanMac only supports Apple Silicon Macs.")
        #endif
    }
}
