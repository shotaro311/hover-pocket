import Foundation

extension OpenAIRealtimeMacOSCapabilityRuntime {
    func executePersonal(
        _ operation: PersonalToolOperation, correlation: String, sessionID: String,
        arguments: CapabilityObject
    ) async throws -> String {
        try operation.validate(arguments, broker: false)
        guard context.registry.availableHandlerKeys.contains(operation.key) else {
            throw CapabilityHandlerError.unavailable("tool")
        }
        if operation.isCalendar { try requireCalendarAccess(sessionID) }
        if let target = try arguments.optionalString("targetId", maxLength: 512) {
            guard personalKnownTargets[sessionID, default: []].contains(target) else {
                return try json([
                    "status": "failed", "code": "unknown_target",
                    "message": "先に一覧から対象を特定してください。複数候補があれば利用者に確認してください。",
                ])
            }
        }
        var brokerArguments = arguments
        var approval: VoiceNativeApprovalRequest?
        if let readOperation = operation.detailOperation {
            let readArguments = arguments["targetId"].map { ["targetId": $0] } ?? [:]
            let read = try await executeCapability(
                correlation: correlation + ".read", sessionID: sessionID,
                planIDPrefix: "voice.personal.read", stepID: "readTarget",
                capability: readOperation.key,
                arguments: readArguments, permission: readOperation.permission)
            guard case .object(let target)? = read["result"], let revision = target["revision"]
            else {
                throw CapabilityHandlerError.readbackMismatch("target")
            }
            brokerArguments["expectedRevision"] = revision
            let label = target["title"] ?? target["body"] ?? .string("メディア")
            let labelText: String
            if case .string(let text) = label { labelText = text } else { labelText = "対象" }
            var detail = VoiceApprovalText.singleLine(labelText, limit: 240)
            if case .string(let start)? = target["start"] { detail += "\n" + start }
            if operation.isCalendar {
                detail +=
                    target["isRecurringSeries"] == .bool(true)
                    ? "\n繰り返し予定の全体が対象です。" : "\nこの予定1件が対象です。"
                if case .integer(let count)? = target["attendeeCount"], count > 0 {
                    detail += "\n参加者\(count)人に更新通知が送られます。"
                }
            }
            if !operation.isDestructive {
                let changes = arguments.filter { $0.key != "targetId" }
                let labels = [
                    "title": "名前", "body": "本文", "color": "色", "remainingSeconds": "残り時間（秒）",
                    "deltaSeconds": "増減する秒数", "start": "開始",
                    "end": "終了", "isAllDay": "終日", "location": "場所", "notes": "説明",
                    "action": "再生操作",
                ]
                for key in changes.keys.sorted() {
                    let value: String
                    switch changes[key] {
                    case .string(let text): value = text
                    case .integer(let number): value = String(number)
                    case .bool(let flag): value = flag ? "はい" : "いいえ"
                    default: value = "変更"
                    }
                    detail +=
                        "\n" + (labels[key] ?? key) + ": "
                        + VoiceApprovalText.singleLine(value, limit: 10000)
                }
            }
            approval = .init(
                kind: operation.isDestructive ? .personalDelete : .personalEdit,
                title: operation.isDestructive ? "この対象を削除・キャンセルしますか？" : "この内容で操作しますか？",
                detail: detail)
        }
        // Grant can be revoked while the confirmation sheet is open.
        let output = try await executeCapability(
            correlation: correlation, sessionID: sessionID,
            planIDPrefix: "voice." + operation.rawValue, stepID: "personalTool",
            capability: operation.key,
            arguments: brokerArguments, permission: operation.permission, approval: approval)
        if operation.isCalendar { try requireCalendarAccess(sessionID) }
        guard case .object(var result)? = output["result"] else {
            throw CapabilityHandlerError.readbackMismatch("result")
        }
        result.removeValue(forKey: "revision")
        var truncatedFields: [CapabilityValue] = []
        for field in ["body", "notes", "title", "location"] {
            if case .string(let text)? = result[field], text.utf8.count > 10000 {
                var shortened = ""
                for character in text {
                    let next = String(character)
                    if shortened.utf8.count + next.utf8.count > 10000 { break }
                    shortened += next
                }
                result[field] = .string(shortened)
                truncatedFields.append(.string(field))
            }
        }
        if !truncatedFields.isEmpty {
            result["truncatedFields"] = .array(truncatedFields)
            result["contentNotice"] = .string("全文ではありません。省略された内容を推測したり、この抜粋で全文を上書きしたりしないでください。")
        }
        if case .array(var items)? = result["items"] {
            while !items.isEmpty {
                guard try CapabilityCanonicalJSON.data(.object(result)).count > 28000 else { break }
                items.removeLast()
                result["items"] = .array(items)
                result["truncated"] = .bool(true)
            }
        }
        if try CapabilityCanonicalJSON.data(.object(result)).count > 30000 {
            result = result.filter { ["targetId", "state", "updatedAt", "remainingSeconds", "isPlaying"].contains($0.key) }
            result["contentOmitted"] = .bool(true)
            result["contentNotice"] = .string("内容が長いため本文は返していません。操作の反映は確認済みです。全文を推測して編集しないでください。")
        }
        rememberPersonalTargets(result, sessionID: sessionID)
        return String(
            decoding: try CapabilityCanonicalJSON.data(
                .object([
                    "status": .string("succeeded"), "readback": .string("verified"),
                    "result": .object(result), "contentIsUntrusted": .bool(true),
                ])), as: UTF8.self)
    }

    private func rememberPersonalTargets(_ result: CapabilityObject, sessionID: String) {
        var targets = personalKnownTargets[sessionID, default: []]
        if case .string(let id)? = result["targetId"] { targets.insert(id) }
        if case .string(let id)? = result["seriesTargetId"] { targets.insert(id) }
        if case .array(let items)? = result["items"] {
            for item in items {
                if case .object(let fields) = item, case .string(let id)? = fields["targetId"] {
                    targets.insert(id)
                }
            }
        }
        if targets.count <= 2048 { personalKnownTargets[sessionID] = targets }
    }
}
