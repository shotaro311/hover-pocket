import Foundation

@MainActor
final class AICommandStore: ObservableObject {
    @Published var input = ""
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var result: ToolResult?
    @Published private(set) var candidates: [PocketAction] = []

    let approvalGate: ApprovalGate

    private let modelProvider: any AIModelProvider
    private let calendarStore: GoogleCalendarStore
    private let calendarTool: CalendarPocketTool
    private let auditLog: AuditLog

    init(
        modelProvider: any AIModelProvider = AppleFoundationModelProvider(),
        calendarStore: GoogleCalendarStore = .shared,
        approvalGate: ApprovalGate = ApprovalGate(),
        auditLog: AuditLog = .shared
    ) {
        self.modelProvider = modelProvider
        self.calendarStore = calendarStore
        self.calendarTool = CalendarPocketTool(store: calendarStore)
        self.approvalGate = approvalGate
        self.auditLog = auditLog
    }

    var pendingAction: PocketAction? {
        approvalGate.pendingAction
    }

    func submit() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isRunning else { return }
        input = ""
        Task {
            await planAndRun(command)
        }
    }

    func selectCandidate(_ action: PocketAction) {
        candidates = []
        result = nil
        auditLog.record(.candidateSelected, action: action)
        handle(action)
    }

    func approvePendingAction() {
        guard let action = approvalGate.approvePendingAction() else { return }
        auditLog.record(.approved, action: action)
        Task {
            await execute(action, approved: true)
        }
    }

    func rejectPendingAction() {
        guard let action = pendingAction else { return }
        approvalGate.rejectPendingAction()
        auditLog.record(.rejected, action: action)
        statusMessage = "Canceled."
        objectWillChange.send()
    }

    private func planAndRun(_ command: String) async {
        isRunning = true
        result = nil
        candidates = []
        statusMessage = "Planning..."

        let context = await makeContext()
        do {
            let plan = try await modelProvider.makeIntentPlan(for: command, context: context)
            auditLog.record(.planned, action: plan.primaryAction, message: plan.modelIdentifier)

            isRunning = false
            if let primaryAction = plan.primaryAction, plan.confidence >= 0.55 {
                candidates = plan.candidates
                handle(primaryAction)
            } else {
                candidates = plan.candidates
                statusMessage = plan.candidates.isEmpty ? "I could not map that to a Phase 1 action." : "Choose the intended action."
            }
        } catch {
            isRunning = false
            let message = Self.safeErrorMessage(error)
            statusMessage = message
            auditLog.record(.failed, message: message)
        }
    }

    private func handle(_ action: PocketAction) {
        if action.requiresApproval {
            approvalGate.requestApproval(for: action)
            statusMessage = "Approval required."
            auditLog.record(.approvalRequested, action: action)
            objectWillChange.send()
            return
        }

        Task {
            await execute(action, approved: false)
        }
    }

    private func execute(_ action: PocketAction, approved: Bool) async {
        isRunning = true
        statusMessage = "Running..."
        let toolResult = await calendarTool.run(action, approved: approved)
        result = toolResult
        statusMessage = toolResult.succeeded ? "Done." : toolResult.title
        isRunning = false
        auditLog.record(toolResult.succeeded ? .executed : .failed, action: action, result: toolResult)
    }

    private func makeContext() async -> AICommandContext {
        calendarStore.restoreConnectionIfNeeded()
        if calendarStore.isSignedIn, calendarStore.writableSources().isEmpty {
            _ = try? await calendarStore.loadMonthForTool(containing: Date())
        }

        let writableCalendars = calendarStore.writableSources().map {
            CalendarToolCalendar(id: $0.id, title: $0.title, isPrimary: $0.isPrimary)
        }

        return AICommandContext(
            now: Date(),
            timeZoneIdentifier: TimeZone.current.identifier,
            writableCalendars: writableCalendars
        )
    }

    private static func safeErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "The command could not be planned."
    }
}
