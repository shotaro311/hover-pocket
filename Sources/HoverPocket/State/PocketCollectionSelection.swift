import Combine
import Foundation

@MainActor
final class PocketCollectionSelection: ObservableObject {
    @Published var snapshot: PocketCollectionSnapshot?
    @Published var selectedID: String?
    @Published var draft: [String: PocketJSONValue] = [:]
    @Published var isEditing = false
    @Published var errorText: String?
    @Published var search = ""
    @Published var pendingDelete: PocketCollectionRecord?
}
