import AppKit
import UserNotifications

/// Posts the "converting / ready / failed" notifications.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let sizes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Screenshot720p notification permission error: \(error)") }
            else if !granted { NSLog("Screenshot720p notifications are turned off") }
        }
    }

    func converting(file: String) {
        post(id: file, title: "Converting video to 720p", body: file, sound: false)
    }

    func ready(file: String, output: String, inSize: Int64, outSize: Int64) {
        let name = (output as NSString).lastPathComponent
        let body = "\(name) — \(sizes.string(fromByteCount: inSize)) → \(sizes.string(fromByteCount: outSize))"
        post(id: file, title: "720p copy ready", body: body, sound: true, path: output)
    }

    func failed(file: String, error: String) {
        post(id: file, title: "Couldn't convert \(file)", body: error, sound: true)
    }

    /// Same id per source file, so "ready" replaces "converting" in Notification Center.
    private func post(id: String, title: String, body: String, sound: Bool, path: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let path { content.userInfo = ["path": path] }
        center.add(UNNotificationRequest(identifier: "job-" + id, content: content, trigger: nil)) { error in
            if let error { NSLog("Screenshot720p could not post notification: \(error)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String,
           FileManager.default.fileExists(atPath: path) {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }
}
