import SwiftUI

struct AiUsagePanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: AiUsageStore
    let isActive: Bool
    let openSettings: () -> Void
    @Environment(\.panelTextSize) private var textSize
    @State private var reordering = AiUsageReordering()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let services = visible.map {
                AiUsagePanelService(id: $0, snapshot: usage.snapshot($0), changingAccount: usage.isChangingAccount($0))
            }
            let now = max(context.date, .now)
            VStack(spacing: 0) {
                header(services)
                if services.isEmpty {
                    ContentUnavailableView {
                        Text(copy.text("表示するサービスがありません", "No services to show"))
                    } actions: {
                        Button(copy.text("AI設定を開く", "Open AI settings"), action: openSettings)
                    }
                } else {
                    GeometryReader { proxy in
                        let limits = rows(in: .limits, from: services)
                        let balances = rows(in: .balances, from: services)
                        VStack(spacing: 4) {
                            if settings.aiUsageLayout == .list, !limits.isEmpty {
                                VStack(spacing: 4) {
                                    sectionTitle(.limits)
                                    listHeader(columns(for: proxy.size.width))
                                }
                                .padding(.horizontal, Self.contentInset)
                            }
                            ScrollView(.vertical) {
                                sectionContent(limits: limits, balances: balances, now: now, width: proxy.size.width)
                            }
                            .scrollIndicators(.hidden)
                        }
                    }
                }
            }
        }
        .font(.system(size: textSize.scaled(12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isActive, initial: true) { _, active in
            if active { usage.refresh(visible) }
            else { reordering.cancel() }
        }
        .onChange(of: settings.aiUsageLayout) { _, _ in reordering.cancel() }
        .onChange(of: settings.aiUsageSort) { _, _ in reordering.cancel() }
        .onChange(of: settings.hiddenAiUsageServices) { _, _ in reordering.cancel() }
        .onDisappear { reordering.cancel() }
    }

    private static let contentInset: CGFloat = 14

    private func columns(for width: CGFloat) -> ListColumns {
        ListColumns(width: max(0, width - 2 * Self.contentInset))
    }

    func panelContent(_ services: [AiUsagePanelService], now: Date, width: CGFloat) -> some View {
        sectionContent(limits: rows(in: .limits, from: services),
                       balances: rows(in: .balances, from: services), now: now, width: width)
    }

    private func rows(in section: AiUsageSection, from services: [AiUsagePanelService]) -> [AiUsagePanelService] {
        section.visibleRows(services, in: reordering.order(in: section, settings: settings))
    }

    private func sectionContent(
        limits: [AiUsagePanelService], balances: [AiUsagePanelService], now: Date, width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !limits.isEmpty {
                if settings.aiUsageLayout == .list {
                    list(limits, now: now, columns: columns(for: width))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle(.limits)
                        meters(limits, now: now)
                    }
                }
            }
            if !balances.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(.balances)
                    balanceCards(balances, now: now)
                }
            }
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.bottom, 12)
    }

    private func sectionTitle(_ section: AiUsageSection) -> some View {
        HStack(spacing: 8) {
            Text(section.title(copy))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(aiUsageColor(0x9ba6b5))
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).accessibilityHidden(true)
        }
    }

    private var visible: [AiUsageService] { settings.visibleAiUsageServices }
    private var copy: AiUsageCopy { .init(language: settings.appLanguage) }

    private func header(_ services: [AiUsagePanelService]) -> some View {
        let refreshing = services.contains { $0.snapshot.refreshing }
        return HStack(spacing: 8) {
            Text("AI Usage").fontWeight(.semibold).lineLimit(1)
            Picker(copy.text("表示", "Layout"), selection: $settings.aiUsageLayout) {
                Text(copy.text("一覧", "List")).tag(AiUsageLayout.list)
                Text(copy.text("メーター", "Meter")).tag(AiUsageLayout.meter)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 4)
            if refreshing {
                Text(copy.text("更新中…", "Refreshing…")).foregroundStyle(.secondary)
            } else if let latest = services.compactMap(\.updateDate).max() {
                Text(copy.updated(latest)).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(action: { usage.refresh(visible, force: true) }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(visible.isEmpty)
            .help(copy.text("更新", "Refresh"))
            .accessibilityLabel(copy.text("更新", "Refresh"))
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func listHeader(_ columns: ListColumns) -> some View {
        HStack(spacing: ListColumns.spacing) {
            Color.clear.frame(width: ListColumns.handle, height: 1).accessibilityHidden(true)
            Group {
                if settings.aiUsageSort == nil {
                    Text(copy.remaining).foregroundStyle(.secondary)
                } else {
                    Button(copy.text("自分の順に戻す", "Back to my order")) { settings.aiUsageSort = nil }
                        .buttonStyle(.borderless)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: columns.name, alignment: .leading)
            ForEach(AiUsageColumn.allCases) { column in
                sortButton(column).frame(width: columns.width(for: column), alignment: .leading)
            }
        }
        .padding(.horizontal, ListColumns.inset)
        .padding(.vertical, 4)
    }

    private func list(_ services: [AiUsagePanelService], now: Date, columns: ListColumns) -> some View {
        let visible = services.map(\.id)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(AiUsagePanelService.sorted(services, by: settings.aiUsageSort)) { service in
                listRow(service, now: now, columns: columns, visible: visible)
            }
        }
    }

    private func sortButton(_ column: AiUsageColumn) -> some View {
        let direction = settings.aiUsageSort.flatMap { $0.column == column ? $0.direction : nil }
        let value: String = switch direction {
        case .asc: copy.text("少ない順", "Ascending")
        case .desc: copy.text("多い順", "Descending")
        case nil: copy.text("指定なし", "Unsorted")
        }
        return Button {
            settings.aiUsageSort = .init(column: column, previous: settings.aiUsageSort)
        } label: {
            HStack(spacing: 4) {
                Text(copy.column(column))
                Image(systemName: direction == .asc ? "arrow.up" : direction == .desc ? "arrow.down" : "arrow.up.arrow.down")
                    .font(.system(size: 9))
                    .opacity(direction == nil ? 0.45 : 1)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityValue(value)
    }

    private func listRow(_ service: AiUsagePanelService, now: Date, columns: ListColumns, visible: [AiUsageService]) -> some View {
        let item = AiUsageOrderItem(service: service.id, section: .limits)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: ListColumns.spacing) {
                Group {
                    if reordering.allowsMovement(in: .limits, settings: settings) { handle(item, title: service.id.title, visible: visible) }
                    else { Color.clear.frame(height: 1).accessibilityHidden(true) }
                }
                .frame(width: ListColumns.handle)
                VStack(alignment: .leading, spacing: 2) {
                    serviceName(service)
                    staleTime(service)
                }
                .frame(width: columns.name, alignment: .leading)
                if service.snapshot.reading == nil {
                    emptyMessage(service)
                        .frame(width: columns.quotaSpan, alignment: .leading)
                } else {
                    ForEach(AiUsageColumn.allCases) { column in
                        let windows = service.windows(in: column)
                        VStack(alignment: .leading, spacing: 5) {
                            if windows.isEmpty { Text("—").foregroundStyle(.secondary) }
                            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                                AiUsageListQuotaView(quota: service.quota(window), copy: copy, now: now,
                                                     readingOpacity: service.readingOpacity)
                            }
                        }
                        .frame(width: columns.width(for: column), alignment: .leading)
                    }
                }
            }
            if service.snapshot.stale, let reason = service.reason(copy) {
                AiUsageReasonText(message: reason)
                    .frame(width: columns.quotaSpan, alignment: .leading)
                    .padding(.leading, ListColumns.handle + columns.name + ListColumns.spacing * 2)
            }
        }
        .padding(.horizontal, ListColumns.inset)
        .padding(.vertical, 6)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .modifier(AiUsageReorderItemStyle(item: item, reordering: reordering, radius: 7, border: 0))
    }

    private func meters(_ services: [AiUsagePanelService], now: Date) -> some View {
        let visible = services.map(\.id)
        return AiUsageFlow(spacing: 8) {
            ForEach(services) { service in
                meterCard(service, now: now, visible: visible)
            }
        }
    }

    private func meterCard(_ service: AiUsagePanelService, now: Date, visible: [AiUsageService]) -> some View {
        let item = AiUsageOrderItem(service: service.id, section: .limits)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                handle(item, title: service.id.title, visible: visible)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        serviceName(service)
                        staleTime(service)
                    }
                    if service.snapshot.stale, let reason = service.reason(copy) {
                        AiUsageReasonText(message: reason)
                    }
                }
            }
            if service.orderedWindows.isEmpty {
                emptyMessage(service)
            } else {
                AiUsageFlow(spacing: 4) {
                    ForEach(Array(service.orderedWindows.enumerated()), id: \.offset) { _, window in
                        AiUsageMeterView(quota: service.quota(window), copy: copy, now: now,
                                         readingOpacity: service.readingOpacity)
                    }
                }
            }
        }
        .padding(8)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .modifier(AiUsageReorderItemStyle(item: item, reordering: reordering, radius: 8))
    }

    private func balanceCards(_ services: [AiUsagePanelService], now: Date) -> some View {
        let visible = services.map(\.id)
        return AiUsageFlow(spacing: 8) {
            ForEach(services) { service in
                balanceCard(service, now: now, visible: visible)
            }
        }
    }

    private func balanceCard(_ service: AiUsagePanelService, now: Date, visible: [AiUsageService]) -> some View {
        let item = AiUsageOrderItem(service: service.id, section: .balances)
        let balance = AiUsagePanelBalance(service)
        let title = balance?.label(copy) ?? service.id.title
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                handle(item, title: title, visible: visible)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(aiUsageColor(0x9ba6b5))
                    .lineLimit(1)
            }
            staleTime(service)
            if let balance {
                AiUsageReadingNumber(
                    amount: copy.balanceValue(balance.total), unit: balance.unit, size: 27, unitSize: 12
                )
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(service.readingOpacity)
                .help(balance.help(copy, now: now))

                if let detail = balance.meterDetail(copy, now: now) {
                    Text(detail).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let reason = service.reason(copy) {
                    AiUsageReasonText(message: reason)
                }
            } else {
                emptyMessage(service, stacked: true)
            }
        }
        .frame(minWidth: 154, maxWidth: 154, minHeight: 68, alignment: .topLeading)
        .padding(8)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .modifier(AiUsageReorderItemStyle(item: item, reordering: reordering, radius: 8))
    }

    private func serviceName(_ service: AiUsagePanelService) -> some View {
        Text(service.id.title).fontWeight(.semibold).lineLimit(1)
    }

    @ViewBuilder
    private func staleTime(_ service: AiUsagePanelService) -> some View {
        if let fetched = service.staleDate {
            Text(copy.stale(fetched)).font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(AiUsageTint.yellow.color)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func emptyMessage(_ service: AiUsagePanelService, stacked: Bool = false) -> some View {
        if service.snapshot.status == .signedOut {
            AiUsageSignedOutView(copy: copy, openSettings: openSettings, stacked: stacked)
        } else {
            AiUsageReasonText(message: service.emptyMessage(copy))
        }
    }

    private func handle(_ item: AiUsageOrderItem, title: String, visible: [AiUsageService]) -> some View {
        AiUsageReorderHandle(item: item, title: title, copy: copy, settings: settings,
                             reordering: reordering, visible: visible)
            .frame(width: 14, height: 17)
    }

    private struct ListColumns {
        static let handle: CGFloat = 14
        static let inset: CGFloat = 8
        static let spacing: CGFloat = 7
        let name: CGFloat
        let quotas: CGFloat
        var quotaSpan: CGFloat { quotas + Self.spacing * 2 }

        init(width: CGFloat) {
            let usable = max(0, width - Self.inset * 2 - Self.spacing * 4 - Self.handle)
            name = min(150, usable * 0.24)
            quotas = usable - name
        }

        func width(for column: AiUsageColumn) -> CGFloat {
            quotas * (column == .other ? 0.39 : 0.305)
        }
    }

}

private struct AiUsageReorderItemStyle: ViewModifier {
    let item: AiUsageOrderItem
    let reordering: AiUsageReordering
    let radius: CGFloat
    var border: Double = 0.12

    func body(content: Content) -> some View {
        let moving = reordering.isMoving(item)
        let outline = moving ? AiUsageTint.blue.color : Color.white.opacity(border)
        return content
            .background {
                GeometryReader { geometry in
                    AiUsageReorderFrame(item: item, reordering: reordering)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius).strokeBorder(outline, lineWidth: moving ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(moving ? 0.45 : 0), radius: 4, y: 2)
            .zIndex(moving ? 1 : 0)
    }
}

struct AiUsageSignedOutView: View {
    let copy: AiUsageCopy
    let openSettings: () -> Void
    var stacked = false

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            Text(copy.signedOut).foregroundStyle(.secondary)
            Button(copy.text("設定を開く", "Open Settings"), action: openSettings)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
        }
        .lineLimit(stacked ? 2 : 1)
        .minimumScaleFactor(0.75)
    }
}

struct AiUsageReasonText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: false, vertical: true)
            .help(message)
    }
}

struct AiUsageListQuotaView: View {
    let quota: AiUsageQuota
    let copy: AiUsageCopy
    let now: Date
    var readingOpacity: Double = 1
    @Environment(\.panelTextSize) private var textSize

    private var name: some View {
        AiUsageQuotaLabel(quota: quota, copy: copy)
            .font(.system(size: textSize.scaled(11)))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 64, alignment: .leading)
    }

    var body: some View {
        Group {
            if let remaining = quota.window.remaining {
                if let reset = quota.resetText(copy, now: now) {
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 0) {
                                value(remaining)
                                Spacer(minLength: 6)
                                countdown(reset)
                            }
                            bar(remaining)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            value(remaining)
                            bar(remaining)
                            countdown(reset).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        value(remaining)
                        bar(remaining)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    if quota.window.column == .other { name }
                    Text(copy.unavailable).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
        }
        .help(quota.help(copy))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.meterAccessibility(quota, now: now))
    }

    private func value(_ remaining: Double) -> some View {
        HStack(spacing: 4) {
            if quota.window.column == .other { name }
            AiUsageReadingNumber(
                amount: String(copy.percent(remaining).dropLast()), unit: "%", size: textSize.scaled(13),
                unitSize: textSize.scaled(9), color: AiUsageTint(remaining: remaining).color
            )
                .opacity(readingOpacity)
                .fixedSize()
        }
    }

    private func countdown(_ text: String) -> some View {
        Text(text).monospacedDigit()
            .font(.system(size: textSize.scaled(11)))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private func bar(_ remaining: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(AiUsageTint(remaining: remaining).color)
                    .frame(width: proxy.size.width * remaining / 100)
            }
        }
        .frame(height: 5)
        .opacity(readingOpacity)
        .accessibilityHidden(true)
    }
}

struct AiUsageFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, layout.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            guard size.width > 0, size.height > 0 else {
                frames.append(.zero)
                continue
            }
            if x > 0 && x + size.width > width + 0.01 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}
