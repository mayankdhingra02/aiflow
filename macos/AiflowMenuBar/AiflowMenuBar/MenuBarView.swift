import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: WidgetViewModel
    @State private var renaming: SavedProject?
    @State private var removing: SavedProject?
    @State private var confirmingCancel = false

    /// What the window is currently asking the user for.
    ///
    /// Everything renders inline in the one `MenuBarExtra` window. Sheets and alerts are
    /// deliberately not used here: presenting either one takes key window away from a
    /// `.menuBarExtraStyle(.window)` popover, which macOS then dismisses — so the popup
    /// vanished mid-interaction and the user had to click the menu bar icon again.
    private enum Mode: Equatable {
        case normal
        case confirmingCancel
        case approval
        case question
        case confirmingRun(SavedProject)
        case renaming(SavedProject)
        case removing(SavedProject)
    }

    private var mode: Mode {
        // A cancel the user already asked for outranks anything the run is waiting on.
        if confirmingCancel, viewModel.isRunning { return .confirmingCancel }
        if viewModel.pendingApproval != nil { return .approval }
        if viewModel.pendingQuestion != nil { return .question }
        if let project = viewModel.confirmingProject { return .confirmingRun(project) }
        if let project = renaming { return .renaming(project) }
        if let project = removing { return .removing(project) }
        return .normal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .normal:
                promptSection
                selectorsSection
                projectsSection
                Divider()
                statusSection

            case .confirmingRun(let project):
                runConfirmPanel(project)

            case .confirmingCancel:
                cancelConfirmPanel

            case .approval:
                if let request = viewModel.pendingApproval {
                    ApprovalPanel(request: request, viewModel: viewModel)
                }

            case .question:
                if let question = viewModel.pendingQuestion {
                    QuestionPanel(question: question, viewModel: viewModel)
                        // Fresh answer state per request.
                        .id(question.id.notificationValue)
                }

            case .renaming(let project):
                RenamePanel(project: project) { newName in
                    if let newName { viewModel.rename(project, to: newName) }
                    renaming = nil
                }

            case .removing(let project):
                removePanel(project)
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { await viewModel.refresh() }
        .onAppear { viewModel.popoverDidBecomeVisible() }
        .onDisappear { viewModel.popoverDidBecomeHidden() }
        // A run that ends on its own retires a cancel prompt that is no longer meaningful.
        .onChange(of: viewModel.isRunning) { running in
            if !running { confirmingCancel = false }
        }
    }

    // MARK: - Inline lifecycle panels

    private func runConfirmPanel(_ project: SavedProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run Prompt?").font(.headline)

            field("Project", project.name)
            field(
                "Model",
                viewModel.models.first { $0.role == viewModel.selectedModelRole }?.displayName
                    ?? viewModel.selectedModelRole)
            field("Thinking", displayNameForEffort(viewModel.selectedEffort))

            VStack(alignment: .leading, spacing: 2) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                Text(String(viewModel.clipboardPrompt.prefix(200)))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Back") { viewModel.cancelConfirmation() }
                Spacer()
                Button("Run Codex") { viewModel.confirmRun() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var cancelConfirmPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cancel Codex run?").font(.headline)
            Text("Codex will stop and the current approval or question, if any, will be dismissed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Keep Running") { confirmingCancel = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Cancel Run", role: .destructive) {
                    viewModel.cancelRun()
                    confirmingCancel = false
                }
            }
        }
    }

    private func removePanel(_ project: SavedProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove project?").font(.headline)
            Text("Aiflow will forget \(project.name). The repository on disk is not changed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { removing = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove", role: .destructive) {
                    viewModel.remove(project)
                    removing = nil
                }
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }

    // MARK: - Sections

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.refreshClipboard()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read the clipboard again")
            }

            Text(viewModel.hasPrompt ? viewModel.clipboardPrompt : "No text prompt in clipboard")
                .font(.caption)
                .foregroundStyle(viewModel.hasPrompt ? .primary : .secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))

            if viewModel.hasPrompt {
                Text("\(viewModel.promptCharacterCount) characters")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var selectorsSection: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $viewModel.selectedModelRole) {
                    ForEach(viewModel.models) { Text($0.displayName).tag($0.role) }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Thinking").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $viewModel.selectedEffort) {
                    ForEach(viewModel.efforts, id: \.self) {
                        Text(displayNameForEffort($0)).tag($0)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Projects").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Approval: Manual").font(.caption2).foregroundStyle(.secondary)
            }

            if viewModel.savedProjects.isEmpty {
                Text("No projects yet. Add one below.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                projectButtons
            }

            Button("+ Add Project") { addProject() }
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var projectButtons: some View {
        let content = VStack(spacing: 6) {
            ForEach(viewModel.savedProjects) { project in
                projectButton(project)
            }
        }

        // Keep the popover compact once the list grows.
        if viewModel.savedProjects.count > 5 {
            ScrollView { content }.frame(maxHeight: 190)
        } else {
            content
        }
    }

    private func projectButton(_ project: SavedProject) -> some View {
        Button {
            viewModel.requestRun(project)
        } label: {
            HStack(spacing: 6) {
                if viewModel.isRunning(project) {
                    ProgressView().controlSize(.small)
                } else if viewModel.isMapped(project) {
                    Circle().fill(.tint).frame(width: 7, height: 7)
                }
                Text(project.name).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .disabled(!viewModel.canRunProjects)
        .help(project.path)
        .contextMenu {
            Button("Map Current Chat") { viewModel.mapCurrentChat(to: project) }
            if viewModel.isMapped(project) {
                Button("Remove Chat Mapping") { viewModel.unmapCurrentChat() }
            }
            Divider()
            Button("Rename…") { renaming = project }
            Button("Reveal in Finder") { viewModel.revealInFinder(project) }
            Button("Open README in VS Code") { viewModel.openReadmeInCompanion(project) }
            Divider()
            Button("Remove", role: .destructive) { removing = project }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if viewModel.isRunning { ProgressView().controlSize(.small) }
                Text("Status: \(viewModel.runState.statusText)")
                    .font(.caption).foregroundStyle(statusColor)
                Spacer()
                if viewModel.isRunning {
                    Button("Cancel Run") { confirmingCancel = true }
                        .buttonStyle(.borderless).font(.caption2)
                }
            }

            if !viewModel.notice.isEmpty {
                Text(viewModel.notice).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }

            if !viewModel.lastMessage.isEmpty {
                Text(viewModel.lastMessage)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(4)
            }

            HStack(spacing: 6) {
                Text("Chat: \(viewModel.chatDisplay)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button {
                    viewModel.refreshChat()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).font(.caption2)
            }
        }
    }

    private var statusColor: Color {
        switch viewModel.runState {
        case .completed: return .green
        case .failed: return .red
        case .waitingForApproval, .waitingForInput: return .orange
        default: return .secondary
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.addProject(at: url.resolvingSymlinksInPath().path)
        }
    }
}

// MARK: - Inline panels

private struct ApprovalPanel: View {
    let request: ApprovalRequest
    @ObservedObject var viewModel: WidgetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.kind.title).font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                Text("Action").font(.caption).foregroundStyle(.secondary)
                Text(request.summary)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = request.detail {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reason").font(.caption).foregroundStyle(.secondary)
                    Text(detail).font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Project").font(.caption).foregroundStyle(.secondary)
                Text(request.projectName).font(.callout)
            }

            // The decision applies only to this request — there is no "always allow".
            HStack {
                Button("Deny") { viewModel.respondToApproval(allow: false) }
                    .keyboardShortcut(request.prefersDeny ? .defaultAction : nil)
                Spacer()
                Button("Allow Once") { viewModel.respondToApproval(allow: true) }
                    .keyboardShortcut(request.prefersDeny ? nil : .defaultAction)
            }
        }
    }
}

/// Answers every question in one request. A request may carry several questions, each
/// either a set of options or free text, and all of them must be answered.
private struct QuestionPanel: View {
    let question: UserQuestion
    @ObservedObject var viewModel: WidgetViewModel
    @State private var answers: [String: String] = [:]

    private var isComplete: Bool {
        question.questions.allSatisfy {
            !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.questions.count > 1 ? "Codex asks a few things" : "Codex asks")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(question.questions) { item in
                        questionView(item)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Button("Cancel Run") { viewModel.cancelRun() }
                Spacer()
                Button("Send") { viewModel.respondToQuestion(answers) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
        }
    }

    @ViewBuilder
    private func questionView(_ item: QuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !item.header.isEmpty {
                Text(item.header).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.question).font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !item.options.isEmpty {
                ForEach(item.options) { option in
                    Button {
                        answers[item.id] = option.label
                    } label: {
                        HStack(spacing: 6) {
                            Image(
                                systemName: answers[item.id] == option.label
                                    ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).font(.caption)
                                if !option.description.isEmpty {
                                    Text(option.description)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Free text when there are no options, or when "Other" is allowed alongside them.
            if item.allowsFreeForm {
                let isOtherField = !item.options.isEmpty
                if item.isSecret {
                    SecureField(
                        isOtherField ? "Other…" : "Your answer",
                        text: binding(for: item.id)
                    )
                    .textFieldStyle(.roundedBorder)
                } else {
                    TextField(
                        isOtherField ? "Other…" : "Your answer",
                        text: binding(for: item.id)
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}

private struct RenamePanel: View {
    let project: SavedProject
    /// nil means the user backed out.
    let onFinish: (String?) -> Void
    @State private var name: String

    init(project: SavedProject, onFinish: @escaping (String?) -> Void) {
        self.project = project
        self.onFinish = onFinish
        _name = State(initialValue: project.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename Project").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onFinish(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
