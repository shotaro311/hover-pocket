import Foundation

struct PocketSurfaceChoice: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
}

@MainActor
final class PocketSurfaceHostModel: ObservableObject {
    let packageName: String
    let surface: PocketSurfaceDocument

    @Published private(set) var inputs: [String: CapabilityValue] = [:]
    @Published private(set) var state: [String: CapabilityValue] = [:]
    @Published private(set) var choicesByQuery: [String: [PocketSurfaceChoice]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isExecuting = false
    @Published private(set) var statusText: String?
    @Published private(set) var receiptText: String?
    @Published var showsApproval = false
    @Published private(set) var approvalText = ""

    private let runtime: PocketAppExecutionRuntime
    private var pendingDraft: PocketAppWorkflowDraft?
    private var didLoad = false

    init(runtime: PocketAppExecutionRuntime, surfaceID: String) throws {
        guard let surface = runtime.package.surfaces[surfaceID] else {
            throw CapabilityBrokerError.invalidPlan("pocket_surface")
        }
        self.runtime = runtime
        self.surface = surface
        self.packageName = runtime.package.manifest.name
        applyDefaults(in: surface.root)
    }

    func load(now: Date = Date()) async {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        statusText = nil
        defer { isLoading = false }

        do {
            for query in queryBindings(in: surface.root) {
                let output = try await runtime.query(
                    reference: query.reference,
                    arguments: query.arguments,
                    now: now
                )
                let choices = Self.makeChoices(output)
                choicesByQuery[query.reference] = choices
                if let first = choices.first {
                    set(.string(first.id), for: query.selection)
                    if let titleTarget = query.titleTarget {
                        set(.string(Self.sanitizeVisibleText(first.title)), for: titleTarget)
                    }
                }
            }
        } catch {
            statusText = "今日の予定を読み込めませんでした。"
        }
    }

    func stringValue(for binding: String) -> String {
        guard case .string(let value)? = value(for: binding) else { return "" }
        return value
    }

    func integerValue(for binding: String) -> Int {
        switch value(for: binding) {
        case .integer(let value): return value
        case .number(let value): return Int(value)
        default: return 0
        }
    }

    func boolValue(for binding: String) -> Bool {
        guard case .bool(let value)? = value(for: binding) else { return false }
        return value
    }

    func updateString(_ value: String, binding: String, maximumLength: Int? = nil) {
        let safeValue = Self.sanitizeVisibleText(value)
        let bounded = maximumLength.map { safeValue.prefixingUnicodeScalars($0) } ?? safeValue
        set(.string(bounded), for: binding)
    }

    func updateInteger(_ value: Int, binding: String) {
        set(.integer(value), for: binding)
    }

    func updateBool(_ value: Bool, binding: String) {
        set(.bool(value), for: binding)
    }

    func selectChoice(_ id: String, query: String, selection: String, titleTarget: String?) {
        set(.string(id), for: selection)
        guard let titleTarget,
              let choice = choicesByQuery[query]?.first(where: { $0.id == id }) else { return }
        set(.string(Self.sanitizeVisibleText(choice.title)), for: titleTarget)
    }

    func canPrepare(workflowID: String) -> Bool {
        guard let workflow = runtime.package.workflows[workflowID] else { return false }
        return workflow.inputs.allSatisfy { name, type in
            guard let value = inputs[name] ?? state[name] else { return false }
            if type == "string" || type == "entity-ref" {
                guard case .string(let text) = value else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    func prepare(workflowID: String) {
        guard !isExecuting else { return }
        do {
            guard let workflow = runtime.package.workflows[workflowID] else {
                throw CapabilityBrokerError.invalidPlan("pocket_workflow")
            }
            var workflowInputs: [String: CapabilityValue] = [:]
            for name in workflow.inputs.keys {
                guard let value = inputs[name] ?? state[name] else {
                    throw CapabilityBrokerError.invalidPlan("pocket_input_\(name)")
                }
                workflowInputs[name] = value
            }
            let draft = try runtime.prepare(workflowID: workflowID, inputs: workflowInputs)
            pendingDraft = draft
            approvalText = Self.approvalSummary(draft)
            showsApproval = true
            receiptText = nil
            statusText = nil
        } catch {
            statusText = "入力内容を確認してください。"
        }
    }

    func approve() {
        guard let draft = pendingDraft else { return }
        showsApproval = false
        pendingDraft = nil
        isExecuting = true
        Task {
            defer { isExecuting = false }
            do {
                let receipt = try await runtime.approveAndExecute(draft)
                let verified = receipt.steps.filter { $0.readback.status == .verified }.count
                guard receipt.status == .succeeded, verified == receipt.steps.count else {
                    statusText = "処理結果を確認できませんでした。"
                    return
                }
                receiptText = "TimerとSticky Notesへ反映しました（\(verified)件確認済み）"
            } catch {
                statusText = "処理を完了できませんでした。"
            }
        }
    }

    func reject() {
        guard let draft = pendingDraft else { return }
        showsApproval = false
        pendingDraft = nil
        runtime.reject(draft)
        statusText = "変更をキャンセルしました。"
    }

    private func value(for binding: String) -> CapabilityValue? {
        if binding.hasPrefix("$input.") {
            return inputs[String(binding.dropFirst("$input.".count))]
        }
        if binding.hasPrefix("$state.") {
            return state[String(binding.dropFirst("$state.".count))]
        }
        return nil
    }

    private func set(_ value: CapabilityValue, for binding: String) {
        if binding.hasPrefix("$input.") {
            inputs[String(binding.dropFirst("$input.".count))] = value
        } else if binding.hasPrefix("$state.") {
            let name = String(binding.dropFirst("$state.".count))
            state[name] = value
            if runtime.package.workflows.values.contains(where: { $0.inputs[name] != nil }) {
                inputs[name] = value
            }
        }
    }

    private func applyDefaults(in node: PocketSurfaceRenderNode) {
        switch node.type {
        case "durationPicker":
            if let binding = node.stringProperty("value"),
               let value = node.integerProperty("default") {
                set(.integer(value), for: binding)
            }
        case "textField", "picker":
            if let binding = node.stringProperty("value"), value(for: binding) == nil {
                set(.string(""), for: binding)
            }
        case "toggle":
            if let binding = node.stringProperty("value"), value(for: binding) == nil {
                set(.bool(false), for: binding)
            }
        default:
            break
        }
        node.children.forEach(applyDefaults)
    }

    private struct QueryBinding {
        let reference: String
        let arguments: [String: PocketJSONValue]
        let selection: String
        let titleTarget: String?
    }

    private func queryBindings(in node: PocketSurfaceRenderNode) -> [QueryBinding] {
        var result: [QueryBinding] = []
        if node.type == "calendarEventPicker",
           case .object(let items)? = node.properties["items"],
           case .string(let reference)? = items["query"],
           case .object(let arguments)? = items["arguments"],
           let selection = node.stringProperty("selection") {
            result.append(QueryBinding(
                reference: reference,
                arguments: arguments,
                selection: selection,
                titleTarget: node.stringProperty("titleTarget")
            ))
        }
        for child in node.children {
            result.append(contentsOf: queryBindings(in: child))
        }
        return result
    }

    private static func makeChoices(_ output: CapabilityObject) -> [PocketSurfaceChoice] {
        guard let values = output.values.compactMap({ value -> [CapabilityValue]? in
            guard case .array(let values) = value else { return nil }
            return values
        }).first else { return [] }
        return values.compactMap { value in
            guard case .object(let object) = value,
                  let id = string(object["eventRef"] ?? object["id"] ?? object["key"]),
                  let title = string(object["safeTitle"] ?? object["title"] ?? object["name"]) else {
                return nil
            }
            let start = string(object["start"])
            let end = string(object["end"])
            return PocketSurfaceChoice(
                id: id,
                title: title,
                subtitle: timeRange(start: start, end: end)
            )
        }
    }

    private static func string(_ value: CapabilityValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func timeRange(start: String?, end: String?) -> String? {
        guard let start, let end,
              let startDate = CapabilityDateCodec.date(from: start),
              let endDate = CapabilityDateCodec.date(from: end) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return "\(formatter.string(from: startDate))–\(formatter.string(from: endDate))"
    }

    private static func approvalSummary(_ draft: PocketAppWorkflowDraft) -> String {
        var lines: [String] = []
        for step in draft.plan.steps {
            switch step.capability {
            case PocketCapabilityKeys.timerStart:
                let title = string(step.arguments["title"]) ?? "Focus"
                let seconds: Int
                switch step.arguments["durationSeconds"] {
                case .integer(let value): seconds = value
                case .number(let value): seconds = Int(value)
                default: seconds = 0
                }
                lines.append("「\(title)」のタイマーを\(max(1, seconds / 60))分で開始")
            case PocketCapabilityKeys.stickyUpsert:
                let body = string(step.arguments["body"]) ?? "今日の目的"
                lines.append("Sticky Notesへ「\(body)」を保存")
            default:
                lines.append(step.capability.id)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func sanitizeVisibleText(_ value: String) -> String {
        let bidirectionalControls: Set<UInt32> = [
            0x061C, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069
        ]
        var result = ""
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            let disallowed = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || bidirectionalControls.contains(scalar.value)
            if disallowed || CharacterSet.whitespaces.contains(scalar) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(String(scalar))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PocketSurfaceRenderNode {
    func stringProperty(_ key: String) -> String? {
        guard case .string(let value)? = properties[key] else { return nil }
        return value
    }

    func integerProperty(_ key: String) -> Int? {
        guard case .number(let value)? = properties[key],
              value.rounded() == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
