import SwiftUI
import AppKit

@main
struct IOSVirtualDeviceLabApp: App {
    @StateObject private var model = LabAppModel()
    @StateObject private var launchHealth = LaunchHealthMonitor.shared

    init() {
        LaunchHealthMonitor.shared.begin(paths: .default)
    }

    var body: some Scene {
        WindowGroup {
            LabRootView()
                .environmentObject(model)
                .environmentObject(launchHealth)
                .frame(minWidth: 1_050, minHeight: 680)
                .task {
                    await model.bootstrap(safeMode: launchHealth.record.safeMode)
                    launchHealth.markReady()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    launchHealth.markCleanExit()
                }
        }
        .defaultSize(width: 1_240, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Lab") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            LabSettingsView()
                .environmentObject(model)
                .environmentObject(launchHealth)
                .frame(width: 560, height: 320)
        }
    }
}
