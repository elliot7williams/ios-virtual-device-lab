import SwiftUI

@main
struct IOSVirtualDeviceLabApp: App {
    @StateObject private var model = LabAppModel()

    var body: some Scene {
        WindowGroup {
            LabRootView()
                .environmentObject(model)
                .frame(minWidth: 1_050, minHeight: 680)
                .task { await model.bootstrap() }
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
                .frame(width: 560, height: 320)
        }
    }
}
