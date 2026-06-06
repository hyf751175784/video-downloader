import SwiftUI
import UserNotifications

extension Notification.Name {
    static let showVideoDownloaderSettings = Notification.Name("showVideoDownloaderSettings")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var viewModel: DownloadViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.prepareForTermination()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@main
struct VideoDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = DownloadViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .onAppear { appDelegate.viewModel = vm }
                .frame(minWidth: 860, idealWidth: 980, minHeight: 620, idealHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("设置...") {
                    NotificationCenter.default.post(name: .showVideoDownloaderSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste & Detect") {
                    vm.pasteAndDetect()
                }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}
