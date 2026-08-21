import AppKit
import Foundation
import UserNotifications

/// Narrow boundary around local notifications. Notification taps never decide an approval;
/// they only activate Aiflow, so an old notification cannot approve a newer request.
@MainActor
protocol NotificationManaging: AnyObject {
    func prepareForRun() async -> Bool
    func sendApproval(for request: ApprovalRequest)
    func sendQuestion(for question: UserQuestion)
    func sendCompletion(for project: SavedProject)
    func sendFailure(for project: SavedProject?)
    func sendReviewShipped(projectName: String)
    func sendReviewNeedsAttention(projectName: String, reason: String)
    func sendReviewAutomationBlocked(reason: String)
    func removePendingRequest(id: CodexRequestID)
}

extension NotificationManaging {
    func sendReviewShipped(projectName: String) {}
    func sendReviewNeedsAttention(projectName: String, reason: String) {}
    func sendReviewAutomationBlocked(reason: String) {}
}

@MainActor
final class NotificationManager: NSObject, NotificationManaging, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    /// This is deliberately deferred until the user starts a run. Declining permission is
    /// non-fatal: the menu-bar attention state remains the reliable fallback.
    func prepareForRun() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    func sendApproval(for request: ApprovalRequest) {
        send(
            identifier: approvalIdentifier(request.id),
            title: "Aiflow — Approval Needed",
            body: "Codex needs your approval for \(request.projectName).")
    }

    func sendQuestion(for question: UserQuestion) {
        send(
            identifier: questionIdentifier(question.id),
            title: "Aiflow — Codex Has a Question",
            body: "Codex needs your input for \(question.projectName).")
    }

    func sendCompletion(for project: SavedProject) {
        send(
            identifier: "aiflow.completion.\(UUID().uuidString)",
            title: "Aiflow — Codex Finished",
            body: "\(project.name) completed successfully.")
    }

    func sendFailure(for project: SavedProject?) {
        let name = project?.name ?? "Codex"
        send(
            identifier: "aiflow.failure.\(UUID().uuidString)",
            title: "Aiflow — Codex Failed",
            body: "\(name) exited with an error.")
    }

    func sendReviewShipped(projectName: String) {
        send(identifier: "aiflow.review.ship.\(projectName)", title: "Aiflow — Review Shipped", body: "ChatGPT shipped the review loop for \(projectName).")
    }

    func sendReviewNeedsAttention(projectName: String, reason: String) {
        send(identifier: "aiflow.review.attention.\(stableIdentifierComponent(projectName + "\\u{0}" + reason))", title: "Aiflow — Review Needs Attention", body: String(reason.prefix(160)))
    }

    func sendReviewAutomationBlocked(reason: String) {
        send(identifier: "aiflow.review.blocked.\(stableIdentifierComponent(reason))", title: "Aiflow — Review Automation Paused", body: String(reason.prefix(160)))
    }

    private func stableIdentifierComponent(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    func removePendingRequest(id: CodexRequestID) {
        center.removePendingNotificationRequests(withIdentifiers: [
            approvalIdentifier(id), questionIdentifier(id),
        ])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Do not add notification action buttons. A response is intentionally never bound to
        // an approval decision; stale notifications can only bring the user back to Aiflow.
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
        completionHandler()
    }

    private func send(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func approvalIdentifier(_ id: CodexRequestID) -> String { "aiflow.approval.\(id.notificationValue)" }
    private func questionIdentifier(_ id: CodexRequestID) -> String { "aiflow.question.\(id.notificationValue)" }
}
