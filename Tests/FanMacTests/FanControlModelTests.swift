import XCTest
@testable import FanMacCore

final class FanControlModelTests: XCTestCase {
    @MainActor
    func testZeroMinimumStaysInMacOSControlBelowBoostThreshold() {
        let backend = FakeFanBackend()
        backend.temperatureCelsius = 50
        let settings = ControlSettings(
            minimumSpeedPercent: 0,
            rampStartCelsius: 80,
            fullSpeedCelsius: 105
        )
        let model = FanControlModel(backend: backend, settings: settings)
        model.refresh()

        model.setEnabled(true)

        XCTAssertTrue(model.isControlEnabled)
        XCTAssertTrue(model.isUsingSystemAutomaticControl)
        XCTAssertTrue(backend.appliedTargets.isEmpty, "AUTO must never write a zero-RPM target")
        XCTAssertEqual(backend.releaseCount, 0)
    }

    @MainActor
    func testZeroMinimumTakesManualControlOnlyAboveBoostThreshold() {
        let backend = FakeFanBackend()
        backend.temperatureCelsius = 50
        let settings = ControlSettings(
            minimumSpeedPercent: 0,
            rampStartCelsius: 80,
            fullSpeedCelsius: 100
        )
        let model = FanControlModel(backend: backend, settings: settings)
        model.refresh()
        model.setEnabled(true)

        backend.temperatureCelsius = 90
        model.refresh()

        XCTAssertFalse(model.isUsingSystemAutomaticControl)
        XCTAssertEqual(backend.appliedTargets.count, 1)
        XCTAssertGreaterThanOrEqual(backend.appliedTargets[0][0], 1_200)
    }

    @MainActor
    func testCoolingBelowBoostReturnsToMacOSWithoutDisarmingCurve() {
        let backend = FakeFanBackend()
        backend.temperatureCelsius = 90
        let settings = ControlSettings(
            minimumSpeedPercent: 0,
            rampStartCelsius: 80,
            fullSpeedCelsius: 100
        )
        let model = FanControlModel(backend: backend, settings: settings)
        model.refresh()
        model.setEnabled(true)

        backend.temperatureCelsius = 50
        model.refresh()

        XCTAssertTrue(model.isControlEnabled)
        XCTAssertTrue(model.isUsingSystemAutomaticControl)
        XCTAssertEqual(backend.releaseCount, 1)
        XCTAssertFalse(backend.isManual)
    }

    @MainActor
    func testLostTemperatureTelemetryRestoresSystemControlAndDisablesCurve() {
        let backend = FakeFanBackend()
        let model = FanControlModel(backend: backend, settings: ControlSettings())
        model.refresh()
        model.setEnabled(true)
        XCTAssertTrue(backend.isManual)

        backend.temperatureCelsius = nil
        model.refresh()

        XCTAssertFalse(model.isControlEnabled)
        XCTAssertTrue(model.isUsingSystemAutomaticControl)
        XCTAssertEqual(backend.releaseCount, 1)
        XCTAssertFalse(backend.isManual)
        XCTAssertNotNil(model.lastError)
    }

    @MainActor
    func testUnexpectedLossOfManualModeReappliesTheCurve() {
        let backend = FakeFanBackend()
        let model = FanControlModel(backend: backend, settings: ControlSettings())
        model.refresh()
        model.setEnabled(true)
        XCTAssertEqual(backend.appliedTargets.count, 1)

        backend.isManual = false
        model.refresh()

        XCTAssertEqual(backend.appliedTargets.count, 2)
        XCTAssertTrue(backend.isManual)
    }

    @MainActor
    func testInitialApplyFailureAttemptsToRestoreSystemControl() {
        let backend = FakeFanBackend()
        backend.applyError = TestError.applyFailed
        let model = FanControlModel(backend: backend, settings: ControlSettings())
        model.refresh()

        model.setEnabled(true)

        XCTAssertFalse(model.isControlEnabled)
        XCTAssertTrue(model.isUsingSystemAutomaticControl)
        XCTAssertEqual(backend.releaseCount, 1)
        XCTAssertNotNil(model.lastError)
    }

    @MainActor
    func testTurningOffReleasesControlAndPreventsFurtherWrites() {
        let backend = FakeFanBackend()
        let model = FanControlModel(backend: backend, settings: ControlSettings())
        model.refresh()

        model.setEnabled(true)
        XCTAssertTrue(model.isControlEnabled)
        XCTAssertEqual(backend.prepareCount, 1)
        XCTAssertEqual(backend.appliedTargets.count, 1)

        model.setEnabled(false)
        XCTAssertFalse(model.isControlEnabled)
        XCTAssertEqual(backend.releaseCount, 1)

        model.setMinimumSpeedPercent(40)
        model.refresh()
        XCTAssertEqual(backend.appliedTargets.count, 1, "Off must not apply curve changes")
    }

    @MainActor
    func testFailedReleaseKeepsControlVisiblyEnabled() {
        let backend = FakeFanBackend()
        let model = FanControlModel(backend: backend, settings: ControlSettings())
        model.refresh()
        model.setEnabled(true)
        backend.releaseError = TestError.releaseFailed

        model.setEnabled(false)

        XCTAssertTrue(model.isControlEnabled)
        XCTAssertNotNil(model.lastError)
    }

    @MainActor
    func testAuthorizationFailureLeavesControlOff() {
        let backend = FakeFanBackend()
        backend.prepareError = TestError.authorizationFailed
        let model = FanControlModel(backend: backend, settings: ControlSettings())
        model.refresh()

        model.setEnabled(true)

        XCTAssertFalse(model.isControlEnabled)
        XCTAssertTrue(backend.appliedTargets.isEmpty)
        XCTAssertNotNil(model.lastError)
    }

    @MainActor
    func testManualModeDetectedAtLaunchCanBeRestored() {
        let backend = FakeFanBackend()
        backend.isManual = true
        let model = FanControlModel(backend: backend, settings: ControlSettings())

        model.refresh()
        XCTAssertTrue(model.isManualModeDetected)

        XCTAssertTrue(model.restoreSystemControl())
        XCTAssertFalse(model.isManualModeDetected)
        XCTAssertEqual(backend.releaseCount, 1)
    }
}

private enum TestError: LocalizedError {
    case authorizationFailed
    case applyFailed
    case releaseFailed

    var errorDescription: String? {
        switch self {
        case .authorizationFailed: return "Authorization failed"
        case .applyFailed: return "Apply failed"
        case .releaseFailed: return "Release failed"
        }
    }
}

private final class FakeFanBackend: FanControlBackend {
    var prepareError: Error?
    var applyError: Error?
    var releaseError: Error?
    var prepareCount = 0
    var releaseCount = 0
    var appliedTargets: [[Int]] = []
    var isManual = false
    var temperatureCelsius: Double? = 60

    func snapshot() -> HardwareSnapshot {
        HardwareSnapshot(
            temperatureCelsius: temperatureCelsius,
            fans: [
                FanReading(
                    id: 0,
                    name: "Fan 1",
                    minimumRPM: 1_200,
                    currentRPM: 2_000,
                    maximumRPM: 6_000,
                    targetRPM: isManual ? 2_500 : 1_200,
                    controlMode: isManual ? 1 : 3
                )
            ],
            status: .connected
        )
    }

    func prepareForControl() throws {
        prepareCount += 1
        if let prepareError { throw prepareError }
    }

    func apply(targetRPMs: [Int]) throws {
        if let applyError { throw applyError }
        appliedTargets.append(targetRPMs)
        isManual = true
    }

    func releaseSystemControl() throws {
        releaseCount += 1
        if let releaseError { throw releaseError }
        isManual = false
    }
}
