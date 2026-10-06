import SwiftUI

struct IconButtonStyle: ButtonStyle {
    let selected: Bool
    var drawsSelection = true

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(label: configuration.label, selected: selected,
                       drawsSelection: drawsSelection, isPressed: configuration.isPressed)
    }
}

private struct IconButtonBody<Label: View>: View {
    let label: Label
    let selected: Bool
    let drawsSelection: Bool
    let isPressed: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Color.white.opacity(hovered ? 0.72 : 0.34))
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isPressed ? 0.16 : selected && drawsSelection ? 0.12 : hovered ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isPressed)
    }
}
