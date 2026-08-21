import AppKit
import Foundation
import UserNotifications

struct AiflowAttentionPreferences: Equatable {
    var systemNotificationsEnabled: Bool
    var autoShowWidgetEnabled: Bool
    var muted: Bool

    init(defaults: UserDefaults) {
        systemNotificationsEnabled = defaults.object(forKey: Self.notificationsKey) as? Bool ?? true
        autoShowWidgetEnabled = defaults.object(forKey: Self.autoShowKey) as? Bool ?? true
        muted = defaults.object(forKey: Self.mutedKey) as? Bool ?? false
    }

    func save(to defaults: UserDefaults) {
        defaults.set(systemNotificationsEnabled, forKey: Self.notificationsKey)
        defaults.set(autoShowWidgetEnabled, forKey: Self.autoShowKey)
        defaults.set(muted, forKey: Self.mutedKey)
    }

    private static let notificationsKey = "aiflow.attention.notifications-enabled"
    private static let autoShowKey = "aiflow.attention.auto-show-widget-enabled"
    private static let mutedKey = "aiflow.attention.muted"
}

enum AiflowAttentionEvent: Equatable {
    case codexCompleted(runId: String, projectName: String)
    case codexFailed(runId: String, projectName: String)
    case codexCancelled(runId: String, projectName: String)
    case approvalRequired(requestId: String, projectName: String)
    case questionRequired(requestId: String, projectName: String)
    case reviewShipped(sourceRunId: String, projectName: String)
    case reviewChangesRequested(sourceRunId: String, projectName: String)
    case reviewManualAttention(sourceRunId: String, projectName: String, reason: String)
    case reviewAutomationBlocked(reason: String)

    var identity: String {
        switch self {
        case let .codexCompleted(runId, _): return "codex.completed.\(runId)"
        case let .codexFailed(runId, _): return "codex.failed.\(runId)"
        case let .codexCancelled(runId, _): return "codex.cancelled.\(runId)"
        case let .approvalRequired(requestId, _): return "approval.\(requestId)"
        case let .questionRequired(requestId, _): return "question.\(requestId)"
        case let .reviewShipped(sourceRunId, _): return "review.ship.\(sourceRunId)"
        case let .reviewChangesRequested(sourceRunId, _): return "review.changes.\(sourceRunId)"
        case let .reviewManualAttention(sourceRunId, _, reason):
            return "review.manual.\(sourceRunId).\(stableIdentifierComponent(reason))"
        case let .reviewAutomationBlocked(reason):
            return "review.blocked.\(stableIdentifierComponent(reason))"
        }
    }
}

@MainActor
protocol AttentionWidgetPresenting: AnyObject {
    var isWidgetVisible: Bool { get }
    func showWidgetIfNeeded()
}

@MainActor
enum AiflowWidgetPresentation {
    static var show: (() -> Void)?
}

@MainActor
protocol AttentionCoordinating: AnyObject {
    var preferences: AiflowAttentionPreferences { get }
    func updatePreferences(_ preferences: AiflowAttentionPreferences)
    func attachPresenter(_ presenter: AttentionWidgetPresenting?)
    func updateWidgetVisibility(_ isVisible: Bool)
    func deliver(_ event: AiflowAttentionEvent)
    func requestNotificationPermissionIfNeeded() async -> Bool
}

extension AttentionCoordinating {
    func updateWidgetVisibility(_ isVisible: Bool) {}
}

@MainActor
final class AttentionCoordinator: AttentionCoordinating {
    private static let deliveredEventIDsKey = "aiflow.attention.delivered-event-ids"

    private let defaults: UserDefaults
    private let notifications: NotificationManaging
    private weak var presenter: AttentionWidgetPresenting?
    private var widgetVisible = false
    private(set) var preferences: AiflowAttentionPreferences

    init(defaults: UserDefaults, notifications: NotificationManaging) {
        self.defaults = defaults
        self.notifications = notifications
        preferences = AiflowAttentionPreferences(defaults: defaults)
    }

    func updatePreferences(_ preferences: AiflowAttentionPreferences) {
        self.preferences = preferences
        preferences.save(to: defaults)
    }

    func attachPresenter(_ presenter: AttentionWidgetPresenting?) {
        self.presenter = presenter
    }

    func updateWidgetVisibility(_ isVisible: Bool) {
        widgetVisible = isVisible
    }

    func requestNotificationPermissionIfNeeded() async -> Bool {
        guard preferences.systemNotificationsEnabled else { return false }
        return await notifications.prepareForRun()
    }

    func deliver(_ event: AiflowAttentionEvent) {
        guard markDelivered(event.identity), !preferences.muted else { return }
        let isWidgetVisible = presenter?.isWidgetVisible ?? widgetVisible

        if preferences.systemNotificationsEnabled, !isWidgetVisible {
            notifications.send(attentionEvent: event)
        }

        if preferences.autoShowWidgetEnabled, !isWidgetVisible {
            presenter?.showWidgetIfNeeded()
        }
    }

    private func markDelivered(_ identity: String) -> Bool {
        var delivered = defaults.stringArray(forKey: Self.deliveredEventIDsKey) ?? []
        guard !delivered.contains(identity) else { return false }
        delivered.append(identity)
        defaults.set(Array(delivered.suffix(256)), forKey: Self.deliveredEventIDsKey)
        return true
    }
}

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
    func send(attentionEvent: AiflowAttentionEvent)
    func removePendingRequest(id: CodexRequestID)
}

extension NotificationManaging {
    func sendReviewShipped(projectName: String) {}
    func sendReviewNeedsAttention(projectName: String, reason: String) {}
    func sendReviewAutomationBlocked(reason: String) {}

    func send(attentionEvent event: AiflowAttentionEvent) {
        switch event {
        case let .reviewShipped(_, projectName):
            sendReviewShipped(projectName: projectName)
        case let .reviewChangesRequested(_, projectName):
            sendReviewNeedsAttention(projectName: projectName, reason: "Changes requested. Follow-up queued.")
        case let .reviewManualAttention(_, projectName, reason):
            sendReviewNeedsAttention(projectName: projectName, reason: reason)
        case let .reviewAutomationBlocked(reason):
            sendReviewAutomationBlocked(reason: reason)
        default:
            break
        }
    }
}

@MainActor
final class NotificationManager: NSObject, NotificationManaging, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

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
        send(identifier: approvalIdentifier(request.id), title: "Aiflow — Approval Needed", body: "Codex needs your approval for \(bounded(request.projectName)).")
    }

    func sendQuestion(for question: UserQuestion) {
        send(identifier: questionIdentifier(question.id), title: "Aiflow — Codex Needs Input", body: "Codex needs your input for \(bounded(question.projectName)).")
    }

    func sendCompletion(for project: SavedProject) {
        send(identifier: "aiflow.completion.\(UUID().uuidString)", title: "Aiflow — Codex Finished", body: "\(bounded(project.name)) completed successfully.")
    }

    func sendFailure(for project: SavedProject?) {
        send(identifier: "aiflow.failure.\(UUID().uuidString)", title: "Aiflow — Codex Failed", body: "\(bounded(project?.name ?? "Codex")) exited with an error.")
    }

    func sendReviewShipped(projectName: String) {
        send(identifier: "aiflow.review.ship.\(stableIdentifierComponent(projectName))", title: "Aiflow — Shipped", body: "\(bounded(projectName)) review loop is complete.")
    }

    func sendReviewNeedsAttention(projectName: String, reason: String) {
        send(identifier: "aiflow.review.attention.\(stableIdentifierComponent(projectName + "\u{0}" + reason))", title: "Aiflow — ChatGPT Review", body: bounded(reason))
    }

    func sendReviewAutomationBlocked(reason: String) {
        send(identifier: "aiflow.review.blocked.\(stableIdentifierComponent(reason))", title: "Aiflow — Review Automation Paused", body: bounded(reason))
    }

    func send(attentionEvent event: AiflowAttentionEvent) {
        let identifier = "aiflow.attention.\(event.identity)"
        switch event {
        case let .codexCompleted(_, projectName):
            send(identifier: identifier, title: "Aiflow — Codex Finished", body: "\(bounded(projectName)) completed.")
        case let .codexFailed(_, projectName):
            send(identifier: identifier, title: "Aiflow — Codex Failed", body: "\(bounded(projectName)) needs attention.")
        case let .codexCancelled(_, projectName):
            send(identifier: identifier, title: "Aiflow — Codex Cancelled", body: "\(bounded(projectName)) was cancelled.")
        case let .approvalRequired(_, projectName):
            send(identifier: identifier, title: "Aiflow — Approval Needed", body: "Codex needs your approval for \(bounded(projectName)).")
        case let .questionRequired(_, projectName):
            send(identifier: identifier, title: "Aiflow — Codex Needs Input", body: "Codex needs your input for \(bounded(projectName)).")
        case let .reviewShipped(_, projectName):
            send(identifier: identifier, title: "Aiflow — Shipped", body: "\(bounded(projectName)) review loop is complete.")
        case let .reviewChangesRequested(_, projectName):
            send(identifier: identifier, title: "Aiflow — ChatGPT Review", body: "\(bounded(projectName)): changes requested. Follow-up queued.")
        case let .reviewManualAttention(_, projectName, reason):
            send(identifier: identifier, title: "Aiflow — ChatGPT Review", body: "\(bounded(projectName)): \(bounded(reason))")
        case let .reviewAutomationBlocked(reason):
            send(identifier: identifier, title: "Aiflow — Review Automation Paused", body: bounded(reason))
        }
    }

    func removePendingRequest(id: CodexRequestID) {
        center.removePendingNotificationRequests(withIdentifiers: [approvalIdentifier(id), questionIdentifier(id)])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            Self.presentWidgetForNotificationTap()
        }
        completionHandler()
    }

    /// A notification tap is presentation-only. It deliberately has no access to a run,
    /// approval, question, or review-dispatch action.
    static func presentWidgetForNotificationTap() {
        NSApp.activate(ignoringOtherApps: true)
        AiflowWidgetPresentation.show?()
    }

    private func send(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = bounded(title, limit: 80)
        content.body = bounded(body)
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func bounded(_ value: String, limit: Int = 160) -> String { String(value.prefix(limit)) }
    private func approvalIdentifier(_ id: CodexRequestID) -> String { "aiflow.approval.\(id.notificationValue)" }
    private func questionIdentifier(_ id: CodexRequestID) -> String { "aiflow.question.\(id.notificationValue)" }
}

private func stableIdentifierComponent(_ value: String) -> String {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}
