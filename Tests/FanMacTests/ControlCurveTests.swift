import XCTest
@testable import FanMacCore

final class ControlCurveTests: XCTestCase {
    func testZeroMinimumUsesSystemControlAtAndBelowBoostThreshold() {
        let settings = ControlSettings(
            minimumSpeedPercent: 0,
            rampStartCelsius: 80,
            fullSpeedCelsius: 105
        )

        XCTAssertTrue(FanCurve.usesSystemAutomaticControl(
            temperatureCelsius: 79,
            settings: settings
        ))
        XCTAssertTrue(FanCurve.usesSystemAutomaticControl(
            temperatureCelsius: 80,
            settings: settings
        ))
        XCTAssertFalse(FanCurve.usesSystemAutomaticControl(
            temperatureCelsius: 81,
            settings: settings
        ))
    }

    func testPositiveMinimumNeverSelectsSystemControlFromTheCurve() {
        let settings = ControlSettings(
            minimumSpeedPercent: 1,
            rampStartCelsius: 80,
            fullSpeedCelsius: 105
        )

        XCTAssertFalse(FanCurve.usesSystemAutomaticControl(
            temperatureCelsius: 40,
            settings: settings
        ))
    }

    func testManualTargetIsClampedToFirmwareLimits() {
        XCTAssertEqual(
            FanCurve.safeManualRPM(requestedRPM: 0, minimumRPM: 1_200, maximumRPM: 6_000),
            1_200
        )
        XCTAssertEqual(
            FanCurve.safeManualRPM(requestedRPM: 9_000, minimumRPM: 1_200, maximumRPM: 6_000),
            6_000
        )
        XCTAssertNil(
            FanCurve.safeManualRPM(requestedRPM: 2_000, minimumRPM: 6_000, maximumRPM: 1_200)
        )
    }

    func testMinimumSpeedIsUsedBelowRampTemperature() {
        let settings = ControlSettings(
            minimumSpeedPercent: 20,
            rampStartCelsius: 60,
            fullSpeedCelsius: 90
        )

        let target = FanCurve.targetRPM(
            temperatureCelsius: 45,
            minimumRPM: 1_200,
            maximumRPM: 6_000,
            settings: settings
        )

        XCTAssertEqual(target, 2_160, accuracy: 0.1)
    }

    func testSpeedRampsLinearlyBetweenThresholds() {
        let settings = ControlSettings(
            minimumSpeedPercent: 10,
            rampStartCelsius: 50,
            fullSpeedCelsius: 90
        )

        let target = FanCurve.targetRPM(
            temperatureCelsius: 70,
            minimumRPM: 1_000,
            maximumRPM: 5_000,
            settings: settings
        )

        XCTAssertEqual(target, 3_200, accuracy: 0.1)
    }

    func testFullSpeedIsCappedAtMaximumRPM() {
        let settings = ControlSettings(
            minimumSpeedPercent: 30,
            rampStartCelsius: 55,
            fullSpeedCelsius: 85
        )

        let target = FanCurve.targetRPM(
            temperatureCelsius: 110,
            minimumRPM: 1_500,
            maximumRPM: 7_500,
            settings: settings
        )

        XCTAssertEqual(target, 7_500, accuracy: 0.1)
    }

    func testInvalidThresholdOrderFailsSafe() {
        let settings = ControlSettings(
            minimumSpeedPercent: 20,
            rampStartCelsius: 80,
            fullSpeedCelsius: 70
        )

        let coolTarget = FanCurve.targetRPM(
            temperatureCelsius: 75,
            minimumRPM: 1_000,
            maximumRPM: 5_000,
            settings: settings
        )
        let hotTarget = FanCurve.targetRPM(
            temperatureCelsius: 85,
            minimumRPM: 1_000,
            maximumRPM: 5_000,
            settings: settings
        )

        XCTAssertEqual(coolTarget, 1_800, accuracy: 0.1)
        XCTAssertEqual(hotTarget, 5_000, accuracy: 0.1)
    }
}
