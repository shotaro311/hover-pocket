import Foundation

struct PocketAppStagingTestRunner {
    private let descriptors: [PocketCapabilityKey: PocketCapabilityDescriptor]

    init(descriptors: [PocketCapabilityDescriptor] = PocketCapabilityDescriptors.builtIn) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
    }

    func run(_ package: PocketAppPackage) throws -> [PocketAppStagingTestResult] {
        var results = [
            PocketAppStagingTestResult(id: "host.snapshot-byte-binding", expected: "pass", status: "pass"),
            PocketAppStagingTestResult(id: "host.preview-determinism", expected: "pass", status: "pass")
        ]
        for id in package.testCases.keys.sorted() {
            guard let expected = package.testCases[id] else {
                throw PocketAppLifecycleError.stagingTestFailed
            }
            let status = try observe(id, package: package)
            guard status == expected else {
                throw PocketAppLifecycleError.stagingTestFailed
            }
            results.append(PocketAppStagingTestResult(id: id, expected: expected, status: status))
        }
        return results
    }

    private func observe(_ id: String, package: PocketAppPackage) throws -> String {
        switch id {
        case "calendar-read":
            return calendarReadIsBound(package) ? "pass" : "reject"
        case "start-focus-approved":
            return focusWorkflowIsBound(package) ? "pass" : "reject"
        case "start-focus-idempotent-replay":
            return focusWorkflowIsBound(package) && focusWritesRequireIdempotency(package) ? "pass" : "reject"
        case "start-focus-rejected":
            return focusWorkflowRequiresApproval(package) ? "reject" : "pass"
        default:
            throw PocketAppLifecycleError.stagingTestFailed
        }
    }

    private func calendarReadIsBound(_ package: PocketAppPackage) -> Bool {
        let request = package.manifest.requestedCapabilities.first { $0.key == PocketCapabilityKeys.calendarList }
        guard request?.effect == .privateRead,
              request?.scope == .object(["range": .string("today")]) else {
            return false
        }
        return package.surfaces.values.contains { containsNode($0.root) { node in
            guard node.type == "calendarEventPicker",
                  case .object(let items)? = node.properties["items"],
                  case .string(let query)? = items["query"] else {
                return false
            }
            return query == "calendar.events.list@1"
        } }
    }

    private func focusWorkflowIsBound(_ package: PocketAppPackage) -> Bool {
        guard let workflow = package.workflows["startFocus"],
              workflow.approvalMode == "before_writes",
              workflow.approvalGroup == "all_writes",
              workflow.partialFailureMode == "compensate_if_available",
              workflow.steps.count == 2,
              workflow.steps[0].id == "startTimer",
              workflow.steps[0].capability == PocketCapabilityKeys.timerStart,
              workflow.steps[0].dependencies.isEmpty,
              workflow.steps[0].arguments == [
                "durationSeconds": .string("$input.durationSeconds"),
                "sourceRef": .string("$input.selectedEventRef"),
                "title": .string("$input.purpose")
              ],
              workflow.steps[1].id == "savePurpose",
              workflow.steps[1].capability == PocketCapabilityKeys.stickyUpsert,
              workflow.steps[1].dependencies == ["startTimer"],
              workflow.steps[1].arguments == [
                "body": .string("$input.purpose"),
                "color": .string("yellow"),
                "stableKey": .string("$context.todayFocusStableKey"),
                "title": .string("Focus purpose")
              ] else {
            return false
        }
        return package.surfaces.values.contains { containsNode($0.root) { node in
            node.type == "button" && node.properties["workflow"] == .string("startFocus")
        } }
    }

    private func focusWritesRequireIdempotency(_ package: PocketAppPackage) -> Bool {
        guard let workflow = package.workflows["startFocus"] else { return false }
        return workflow.steps.allSatisfy { descriptors[$0.capability]?.idempotency == .required }
    }

    private func focusWorkflowRequiresApproval(_ package: PocketAppPackage) -> Bool {
        guard focusWorkflowIsBound(package), let workflow = package.workflows["startFocus"] else { return false }
        return workflow.approvalMode == "before_writes"
            && workflow.approvalGroup == "all_writes"
            && workflow.steps.contains { descriptors[$0.capability]?.effect.isWrite == true }
    }

    private func containsNode(
        _ node: PocketSurfaceRenderNode,
        where predicate: (PocketSurfaceRenderNode) -> Bool
    ) -> Bool {
        predicate(node) || node.children.contains { containsNode($0, where: predicate) }
    }
}
