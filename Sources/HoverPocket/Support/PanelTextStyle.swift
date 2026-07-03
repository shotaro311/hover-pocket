import SwiftUI

private struct PanelTextSizeKey: EnvironmentKey {
    static let defaultValue: PanelTextSizeOption = .small
}

extension EnvironmentValues {
    var panelTextSize: PanelTextSizeOption {
        get { self[PanelTextSizeKey.self] }
        set { self[PanelTextSizeKey.self] = newValue }
    }
}

private struct PanelTextFontModifier: ViewModifier {
    @Environment(\.panelTextSize) private var panelTextSize

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: panelTextSize.scaled(size), weight: weight, design: design))
    }
}

extension View {
    func panelTextFont(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design = .default
    ) -> some View {
        modifier(PanelTextFontModifier(size: size, weight: weight, design: design))
    }
}
