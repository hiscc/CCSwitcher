import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App starts as agent/accessory due to LSUIElement
    }
}

@main
struct CCSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("showUsageInMenuBar") private var showUsageInMenuBar = false

    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CCSwitcherKeepalive") {
            HiddenWindowView()
                .onAppear {
                    // Disabled: silent update check on launch.
                    // Manual check via Settings still works.
                    // updateChecker.checkForUpdates(manual: false)
                    Task {
                        await appState.refresh()
                        appState.startAutoRefresh(interval: refreshInterval)
                    }
                }
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MainMenuView()
                .environmentObject(appState)
                .environmentObject(updateChecker)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updateChecker)
        }
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain.head.profile")
            if showUsageInMenuBar,
               let account = appState.activeAccount,
               let utilization = appState.usage[account.id]?.effectiveSessionUtilization() {
                Text("\(Int(utilization))")
                    .font(.caption)
            }
        }
    }
}
