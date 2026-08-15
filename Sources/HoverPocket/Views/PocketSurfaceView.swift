import SwiftUI

struct PocketSurfaceHostView: View {
    @StateObject private var model: PocketSurfaceHostModel
    @Environment(\.panelTextSize) private var panelTextSize

    init(model: PocketSurfaceHostModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PocketSurfaceNodeView(node: model.surface.root, model: model)

                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("予定を読み込み中")
                }

                if let receiptText = model.receiptText {
                    hostStatus(text: receiptText, color: Color(red: 0.38, green: 0.82, blue: 0.52))
                } else if let statusText = model.statusText {
                    hostStatus(text: statusText, color: .white.opacity(0.58))
                }
            }
            .padding(18)
        }
        .task {
            await model.load()
        }
        .alert("実行前の確認", isPresented: $model.showsApproval) {
            Button("キャンセル", role: .cancel) {
                model.reject()
            }
            Button("実行") {
                model.approve()
            }
        } message: {
            Text(model.approvalText)
        }
    }

    private func hostStatus(text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.receiptText == nil ? "info.circle" : "checkmark.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: panelTextSize.scaled(11), weight: .semibold, design: .rounded))
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }
}

private struct PocketSurfaceNodeView: View {
    let node: PocketSurfaceRenderNode
    @ObservedObject var model: PocketSurfaceHostModel
    @Environment(\.panelTextSize) private var panelTextSize

    var body: some View {
        render(node)
    }

    private func render(_ node: PocketSurfaceRenderNode) -> AnyView {
        switch node.type {
        case "stack":
            let spacing = CGFloat(node.integerProperty("spacing") ?? 0)
            if node.stringProperty("axis") == "horizontal" {
                return AnyView(
                    HStack(alignment: .center, spacing: spacing) {
                        childViews(node.children)
                    }
                )
            }
            return AnyView(
                VStack(alignment: .leading, spacing: spacing) {
                    childViews(node.children)
                }
            )

        case "grid":
            let count = max(1, node.integerProperty("columns") ?? 1)
            let gap = CGFloat(node.integerProperty("gap") ?? 0)
            return AnyView(
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: count),
                    spacing: gap
                ) {
                    childViews(node.children)
                }
            )

        case "text":
            return AnyView(textNode(node))

        case "image":
            let alt = node.stringProperty("alt") ?? "Image"
            return AnyView(
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityLabel(alt)
            )

        case "button":
            let label = node.stringProperty("label") ?? "Run"
            let workflow = node.stringProperty("workflow") ?? ""
            return AnyView(
                Button {
                    model.prepare(workflowID: workflow)
                } label: {
                    HStack(spacing: 8) {
                        if model.isExecuting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(label)
                    }
                    .font(scaledFont(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(red: 0.98, green: 0.76, blue: 0.25))
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.isExecuting || !model.canPrepare(workflowID: workflow))
                .opacity(model.isExecuting || !model.canPrepare(workflowID: workflow) ? 0.45 : 1)
            )

        case "textField":
            let label = node.stringProperty("label") ?? "Text"
            let binding = node.stringProperty("value") ?? ""
            let maximum = node.integerProperty("maxLength") ?? 1_000
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    Text(label)
                        .font(scaledFont(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.48))
                    TextField(label, text: Binding(
                        get: { model.stringValue(for: binding) },
                        set: { model.updateString($0, binding: binding, maximumLength: maximum) }
                    ))
                    .textFieldStyle(.plain)
                    .font(scaledFont(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
            )

        case "toggle":
            let label = node.stringProperty("label") ?? "Toggle"
            let binding = node.stringProperty("value") ?? ""
            return AnyView(
                Toggle(label, isOn: Binding(
                    get: { model.boolValue(for: binding) },
                    set: { model.updateBool($0, binding: binding) }
                ))
                .toggleStyle(.switch)
                .font(scaledFont(size: 11, weight: .semibold))
            )

        case "picker":
            return AnyView(genericPicker(node))

        case "calendarEventPicker":
            return AnyView(calendarEventPicker(node))

        case "durationPicker":
            return AnyView(durationPicker(node))

        case "status":
            let value = node.stringProperty("value") ?? ""
            let tone = node.stringProperty("tone") ?? "neutral"
            return AnyView(
                Text(value)
                    .font(scaledFont(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor(tone))
                    .frame(maxWidth: .infinity, alignment: .leading)
            )

        default:
            return AnyView(EmptyView())
        }
    }

    @ViewBuilder
    private func childViews(_ children: [PocketSurfaceRenderNode]) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            PocketSurfaceNodeView(node: child, model: model)
        }
    }

    private func textNode(_ node: PocketSurfaceRenderNode) -> some View {
        let value = node.stringProperty("value") ?? ""
        let style = node.stringProperty("style") ?? "body"
        return Text(value)
            .font(textFont(style))
            .foregroundStyle(style == "caption" ? .white.opacity(0.5) : .white.opacity(0.94))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func genericPicker(_ node: PocketSurfaceRenderNode) -> some View {
        let label = node.stringProperty("label") ?? "Select"
        let binding = node.stringProperty("value") ?? ""
        let options: [(String, String)]
        if case .array(let values)? = node.properties["options"] {
            options = values.compactMap { value in
                guard case .object(let object) = value,
                      case .string(let optionLabel)? = object["label"],
                      case .string(let optionValue)? = object["value"] else { return nil }
                return (optionLabel, optionValue)
            }
        } else {
            options = []
        }
        return Picker(label, selection: Binding(
            get: { model.stringValue(for: binding) },
            set: { model.updateString($0, binding: binding) }
        )) {
            ForEach(options, id: \.1) { option in
                Text(option.0).tag(option.1)
            }
        }
        .font(scaledFont(size: 11, weight: .semibold))
    }

    private func calendarEventPicker(_ node: PocketSurfaceRenderNode) -> some View {
        let selection = node.stringProperty("selection") ?? ""
        let titleTarget = node.stringProperty("titleTarget")
        let query: String
        if case .object(let items)? = node.properties["items"],
           case .string(let value)? = items["query"] {
            query = value
        } else {
            query = ""
        }
        let choices = model.choicesByQuery[query] ?? []
        return VStack(alignment: .leading, spacing: 7) {
            Text("集中する予定")
                .font(scaledFont(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.48))
            if choices.isEmpty {
                Text(model.isLoading ? "読み込み中…" : "今日の予定はありません")
                    .font(scaledFont(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.vertical, 10)
            } else {
                Picker("集中する予定", selection: Binding(
                    get: { model.stringValue(for: selection) },
                    set: { model.selectChoice($0, query: query, selection: selection, titleTarget: titleTarget) }
                )) {
                    ForEach(choices) { choice in
                        Text(choice.subtitle.map { "\(choice.title)  \($0)" } ?? choice.title)
                            .tag(choice.id)
                    }
                }
                .labelsHidden()
                .font(scaledFont(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func durationPicker(_ node: PocketSurfaceRenderNode) -> some View {
        let binding = node.stringProperty("value") ?? ""
        let minimum = node.integerProperty("min") ?? 60
        let maximum = node.integerProperty("max") ?? 86_400
        let value = model.integerValue(for: binding)
        return Stepper(
            value: Binding(
                get: { max(minimum, min(maximum, model.integerValue(for: binding))) },
                set: { model.updateInteger($0, binding: binding) }
            ),
            in: minimum...maximum,
            step: 60
        ) {
            HStack {
                Text("フォーカスタイマー")
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("\(max(1, value / 60))分")
                    .foregroundStyle(.white)
            }
            .font(scaledFont(size: 11, weight: .bold))
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func textFont(_ style: String) -> Font {
        switch style {
        case "title": scaledFont(size: 16, weight: .bold)
        case "caption": scaledFont(size: 10, weight: .medium)
        case "monospace": scaledFont(size: 11, weight: .medium, design: .monospaced)
        default: scaledFont(size: 12, weight: .medium)
        }
    }

    private func scaledFont(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design = .rounded
    ) -> Font {
        .system(size: panelTextSize.scaled(size), weight: weight, design: design)
    }

    private func statusColor(_ tone: String) -> Color {
        switch tone {
        case "success": Color(red: 0.38, green: 0.82, blue: 0.52)
        case "warning": Color(red: 0.98, green: 0.76, blue: 0.25)
        case "error": Color(red: 1.0, green: 0.38, blue: 0.38)
        default: .white.opacity(0.58)
        }
    }
}
