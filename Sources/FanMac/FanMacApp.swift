import AppKit
import FanMacCore
import SwiftUI

@main
struct FanMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = FanControlModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: FanControlModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fanblades.fill")
                .symbolRenderingMode(.hierarchical)
            Text(model.menuBarTemperatureLabel)
                .monospacedDigit()
        }
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.stop()
        }
    }
}
