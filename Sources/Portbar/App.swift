import AppKit
import SwiftUI

extension AppModel {
    static let shared = AppModel()
}

struct PortbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Logs", id: "logs", for: UUID.self) { $runID in
            LogWindow(runID: runID, model: model)
        }
        .defaultSize(width: 720, height: 440)

        SwiftUI.Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.appWillTerminate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--detect") {
            for path in args.dropFirst(i + 1) {
                let kinds = ProjectCatalog.detectFrameworks(path).map(\.name).joined(separator: ", ")
                let icon = ProjectCatalog.findIcon(in: path).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "-"
                print("\((path as NSString).lastPathComponent): [\(kinds)]  icon: \(icon)")
            }
        } else if args.contains("--dump") {
            DebugTools.dump()
        } else if let i = args.firstIndex(of: "--run-test"), i + 2 < args.count {
            MainActor.assumeIsolated { DebugTools.runTest(dir: args[i + 1], script: args[i + 2]) }
        } else if let i = args.firstIndex(of: "--start"), i + 2 < args.count {
            MainActor.assumeIsolated { DebugTools.startAndLeave(dir: args[i + 1], script: args[i + 2]) }
        } else if args.contains("--adopt") {
            MainActor.assumeIsolated { DebugTools.adopt() }
        } else if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            MainActor.assumeIsolated { DebugTools.render(to: args[i + 1]) }
        } else {
            PortbarApp.main()
        }
    }
}
