import AppKit
import SwiftUI

struct ChatChoiceMenu: NSViewRepresentable {
    struct Choice: Equatable {
        let id: String
        let title: String
    }
    let choices: [Choice]
    let selectedID: String
    let placeholder: String
    let enabled: Bool
    let onChoose: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        makeButton(coordinator: context.coordinator)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        apply(to: button, coordinator: context.coordinator)
    }

    func makeButton(coordinator: Coordinator) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.menu?.autoenablesItems = false
        button.font = .systemFont(ofSize: 10)
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: button, coordinator: coordinator)
        return button
    }

    func apply(to button: NSPopUpButton, coordinator: Coordinator) {
        let current = button.itemArray.map { Choice(id: $0.representedObject as? String ?? "", title: $0.title) }
        let desired = choices.contains(where: { $0.id == selectedID }) ? choices
            : [Choice(id: selectedID, title: placeholder)] + choices
        if current != desired {
            button.removeAllItems()
            for choice in desired {
                let item = NSMenuItem(title: choice.title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.representedObject = choice.id
                item.target = coordinator
                item.isEnabled = choices.contains(where: { $0.id == choice.id })
                button.menu?.addItem(item)
            }
        }
        button.selectItem(at: max(0, desired.firstIndex(where: { $0.id == selectedID }) ?? 0))
        button.isEnabled = enabled && !choices.isEmpty
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ChatChoiceMenu
        var tracked = false
        init(_ parent: ChatChoiceMenu) { self.parent = parent }
        @objc func choose(_ item: NSMenuItem) {
            guard parent.enabled, let id = item.representedObject as? String,
                  parent.choices.contains(where: { $0.id == id }) else { return }
            parent.onChoose(id)
        }
    }
}
