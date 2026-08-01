import Foundation

public struct ControlSettings: Codable, Equatable, Sendable {
    public var minimumSpeedPercent: Double
    public var rampStartCelsius: Double
    public var fullSpeedCelsius: Double

    public init(
        minimumSpeedPercent: Double = 22,
        rampStartCelsius: Double = 55,
        fullSpeedCelsius: Double = 85
    ) {
        self.minimumSpeedPercent = minimumSpeedPercent
        self.rampStartCelsius = rampStartCelsius
        self.fullSpeedCelsius = fullSpeedCelsius
    }
}

public enum FanCurve {
    /// A zero minimum is an opt-out from manual fan control while the CPU is
    /// below the boost threshold. macOS remains responsible for the fans.
    public static func usesSystemAutomaticControl(
        temperatureCelsius: Double,
        settings: ControlSettings
    ) -> Bool {
        guard temperatureCelsius.isFinite else { return true }
        return settings.minimumSpeedPercent <= 0 &&
            temperatureCelsius <= settings.rampStartCelsius
    }

    /// Manual targets must always remain inside the limits reported by SMC.
    /// Invalid telemetry is rejected instead of being turned into a fan write.
    public static func safeManualRPM(
        requestedRPM: Double,
        minimumRPM: Double,
        maximumRPM: Double
    ) -> Double? {
        guard requestedRPM.isFinite,
              minimumRPM.isFinite,
              maximumRPM.isFinite,
              minimumRPM >= 0,
              maximumRPM >= minimumRPM else { return nil }
        return min(max(requestedRPM, minimumRPM), maximumRPM)
    }

    public static func targetRPM(
        temperatureCelsius: Double,
        minimumRPM: Double,
        maximumRPM: Double,
        settings: ControlSettings
    ) -> Double {
        let lowerRPM = min(minimumRPM, maximumRPM)
        let upperRPM = max(minimumRPM, maximumRPM)
        let floorPercent = min(max(settings.minimumSpeedPercent, 0), 100) / 100
        let floorRPM = lowerRPM + ((upperRPM - lowerRPM) * floorPercent)

        guard temperatureCelsius.isFinite,
              lowerRPM.isFinite,
              upperRPM.isFinite,
              upperRPM > lowerRPM else { return lowerRPM.isFinite ? lowerRPM : 0 }
        guard settings.fullSpeedCelsius > settings.rampStartCelsius else {
            return temperatureCelsius >= settings.rampStartCelsius ? upperRPM : floorRPM
        }

        let normalized = (temperatureCelsius - settings.rampStartCelsius) /
            (settings.fullSpeedCelsius - settings.rampStartCelsius)
        let boost = min(max(normalized, 0), 1)
        return floorRPM + ((upperRPM - floorRPM) * boost)
    }
}
