import AppKit
import FanMacCore
import SwiftUI

struct MenuBarPanel: View {
    @ObservedObject var model: FanControlModel
    @State private var isShowingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            sensorCard
            curveCard
            fanCard
            footer
        }
        .frame(width: 380)
        .padding(16)
        .background(Color(red: 0.055, green: 0.065, blue: 0.08))
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("FANMAC")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(1.4)
                Text(model.statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { model.isControlEnabled },
                set: { model.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(model.isChangingControl || model.hardwareStatus != .connected)
            .accessibilityLabel("Enable fan control")
            .help(model.isControlEnabled ? "Return fan control to macOS" : "Enable the CPU-based fan curve")
        }
        .padding(.bottom, 14)
    }

    private var sensorCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("CPU CORE AVERAGE", systemImage: "cpu")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Spacer()
                StatusDot(isActive: model.temperatureCelsius != nil)
            }

            HStack(alignment: .bottom, spacing: 4) {
                Text(model.temperatureLabel)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("°C")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                Spacer()
                TemperatureSparkline(values: model.temperatureHistory)
                    .frame(width: 112, height: 38)
                    .padding(.bottom, 4)
            }

            Text("The only sensor used by the control curve")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
        .padding(.top, 14)
    }

    private var curveCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CONTROL CURVE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    Text(model.curveSummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingSettings.toggle()
                    }
                } label: {
                    Image(systemName: isShowingSettings ? "chevron.up" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isShowingSettings ? "Hide control settings" : "Show control settings")
            }

            CurveBar(
                minimumPercent: model.settings.minimumSpeedPercent,
                rampStart: model.settings.rampStartCelsius,
                fullSpeed: model.settings.fullSpeedCelsius
            )

            if isShowingSettings {
                VStack(spacing: 12) {
                    SettingSlider(
                        title: "Minimum speed",
                        valueText: model.settings.minimumSpeedPercent <= 0
                            ? "AUTO"
                            : "\(Int(model.settings.minimumSpeedPercent))%",
                        value: Binding(
                            get: { model.settings.minimumSpeedPercent },
                            set: { model.setMinimumSpeedPercent($0) }
                        ),
                        range: 0...70,
                        tint: .blue
                    )
                    .help("At 0%, macOS controls the fans until the boost temperature is reached")
                    SettingSlider(
                        title: "Begin boost",
                        valueText: "\(Int(model.settings.rampStartCelsius))°C",
                        value: Binding(
                            get: { model.settings.rampStartCelsius },
                            set: { model.setRampStartCelsius($0) }
                        ),
                        range: 40...80,
                        tint: .orange
                    )
                    SettingSlider(
                        title: "Full speed",
                        valueText: "\(Int(model.settings.fullSpeedCelsius))°C",
                        value: Binding(
                            get: { model.settings.fullSpeedCelsius },
                            set: { model.setFullSpeedCelsius($0) }
                        ),
                        range: 60...105,
                        tint: .red
                    )
                }
                .padding(.top, 2)
                .disabled(model.isChangingControl)
            }
        }
        .padding(.top, 17)
    }

    private var fanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FANS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Spacer()
                if !model.fans.isEmpty {
                    Text("CURRENT / TARGET")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                }
            }

            if model.fans.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.hardwareStatus.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.hardwareMessage ?? "Waiting for a compatible Apple Silicon fan controller.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                ForEach(model.fans) { fan in
                    FanRow(fan: fan, isControlled: model.isActivelyControllingFans || fan.isManualMode)
                }
            }
        }
        .padding(.top, 17)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let lastError = model.lastError {
                Label(lastError, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Label("Apple Silicon only", systemImage: "apple.logo")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Restore system control") {
                    model.restoreSystemControl()
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled((!model.isControlEnabled && !model.isManualModeDetected) || model.isChangingControl)
                .help("Stop manual fan control and return control to macOS")
                Button("Quit") {
                    if model.prepareToQuit() {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .help("Restore system fan control and quit FanMac")
            }
            .padding(.top, 14)
        }
    }
}

private struct StatusDot: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? Color.green : Color.orange)
            .frame(width: 7, height: 7)
            .shadow(color: (isActive ? Color.green : Color.orange).opacity(0.7), radius: 4)
    }
}

private struct CurveBar: View {
    let minimumPercent: Double
    let rampStart: Double
    let fullSpeed: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let floor = max(0, min(1, minimumPercent / 100))
            let start = max(0, min(1, (rampStart - 35) / 70))
            let end = max(start, min(1, (fullSpeed - 35) / 70))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.blue, .orange, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * max(0.1, end))
                    .opacity(0.45 + (floor * 0.55))
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .offset(x: max(0, width * start - 3.5))
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .offset(x: max(0, width * end - 3.5))
            }
        }
        .frame(height: 8)
        .overlay(alignment: .bottomLeading) {
            HStack {
                Text("35°")
                Spacer()
                Text("105°")
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .offset(y: 16)
        }
        .padding(.bottom, 16)
    }
}

private struct SettingSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: 1)
                .tint(tint)
        }
    }
}

private struct FanRow: View {
    let fan: FanReading
    let isControlled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isControlled ? Color.accentColor : .secondary)
                    .frame(width: 22)
                Text(fan.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(fan.currentRPM.rounded()))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if isControlled {
                    Text("/ \(Int((fan.targetRPM ?? fan.currentRPM).rounded())) RPM")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("RPM · SYSTEM")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(isControlled ? Color.accentColor : Color.white.opacity(0.22))
                        .frame(width: proxy.size.width * fan.currentPercent)
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 5)
    }
}

private struct TemperatureSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .stroke(
                LinearGradient(colors: [.blue, .orange], startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let minimum = (values.min() ?? 0) - 1
        let maximum = (values.max() ?? 1) + 1
        let range = max(maximum - minimum, 1)
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height * (1 - CGFloat((value - minimum) / range))
            return CGPoint(x: x, y: y)
        }
    }
}
