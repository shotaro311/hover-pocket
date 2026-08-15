import Foundation

enum CapabilityApprovalTargetState: String, Equatable, Sendable {
    case present
    case missing
}

/// Host-memory-only presentation data. It must not be encoded into contracts,
/// audit logs, receipts, generated surfaces, or agent transcripts.
struct CapabilityApprovalPresentation: Equatable, Sendable {
    let requestID: String
    let planDigest: String
    let stepID: String
    let argumentDigest: String
    let actionKey: String
    let targetKind: String
    let targetDisplayKey: String
    let targetDisplayLabel: String?
    let targetState: CapabilityApprovalTargetState
    let destructive: Bool
    let rollbackAvailable: Bool
}

@MainActor
protocol CapabilityApprovalPresentationResolving {
    func resolve(
        plan: CapabilityExecutionPlan,
        descriptors: [PocketCapabilityDescriptor],
        request: CapabilityApprovalRequest
    ) throws -> [CapabilityApprovalPresentation]
}

@MainActor
struct EmptyCapabilityApprovalPresentationResolver: CapabilityApprovalPresentationResolving {
    func resolve(
        plan _: CapabilityExecutionPlan,
        descriptors _: [PocketCapabilityDescriptor],
        request _: CapabilityApprovalRequest
    ) throws -> [CapabilityApprovalPresentation] {
        []
    }
}

@MainActor
final class HostCapabilityApprovalPresentationResolver: CapabilityApprovalPresentationResolving {
    private static let maximumDisplayScalars = 80
    private let stickyStore: StickyNotesStore

    init(stickyStore: StickyNotesStore) {
        self.stickyStore = stickyStore
    }

    func resolve(
        plan: CapabilityExecutionPlan,
        descriptors: [PocketCapabilityDescriptor],
        request: CapabilityApprovalRequest
    ) throws -> [CapabilityApprovalPresentation] {
        var presentations: [CapabilityApprovalPresentation] = []
        for (step, descriptor) in zip(plan.steps, descriptors) where descriptor.key == PocketCapabilityKeys.stickyDelete {
            let rawID = try step.arguments.requiredString("noteId", maxLength: 128)
            guard let noteID = UUID(uuidString: rawID),
                  let effect = request.effects.first(where: { $0.stepID == step.id }) else {
                throw CapabilityBrokerError.invalidPlan("approval_target")
            }
            let note = stickyStore.note(id: noteID)
            presentations.append(CapabilityApprovalPresentation(
                requestID: request.id,
                planDigest: request.planDigest,
                stepID: step.id,
                argumentDigest: effect.argumentDigest,
                actionKey: "approval.sticky.note.delete",
                targetKind: "sticky_note",
                targetDisplayKey: note == nil
                    ? "approval.target.sticky_note.missing"
                    : "approval.target.sticky_note",
                targetDisplayLabel: note.flatMap { Self.sanitizedDisplayLabel($0.title) },
                targetState: note == nil ? .missing : .present,
                destructive: descriptor.effect == .destructiveSensitive,
                rollbackAvailable: descriptor.rollbackAvailable
            ))
        }
        return presentations
    }

    static func sanitizedDisplayLabel(_ value: String) -> String? {
        var result = ""
        var scalarCount = 0
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !result.isEmpty
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format {
                continue
            }
            if pendingSpace, scalarCount < maximumDisplayScalars {
                result.append(" ")
                scalarCount += 1
                pendingSpace = false
            }
            guard scalarCount < maximumDisplayScalars else { break }
            result.unicodeScalars.append(scalar)
            scalarCount += 1
        }
        let sanitized = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }
}
