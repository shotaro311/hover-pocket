import SwiftUI

struct HoverPillView: View {
    @ObservedObject var settings: AppSettings
    let onEnter: () -> Void
    let onExit: () -> Void
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            TopDockedPillShape(radius: 10)
                .fill(Color.black.opacity(0.94))

            TopDockedPillShape(radius: 10)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.black.opacity(0.94))
                    .frame(height: PanelLayout.topEdgeOverfill)

                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            ZStack {
                handleIcon
            }
            .frame(width: PanelLayout.notchHandleWidth, height: PanelLayout.pillHeight)
        }
        .frame(
            minWidth: PanelLayout.notchHandleWidth,
            idealWidth: PanelLayout.defaultPillWidth,
            maxWidth: .infinity
        )
        .frame(height: PanelLayout.pillHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { inside in
            inside ? onEnter() : onExit()
        }
    }

    @ViewBuilder
    private var handleIcon: some View {
        if !settings.showNotchSideHandleArea {
            EmptyView()
        } else {
            switch settings.pillHandleIconStyle {
            case .chevron:
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
            case .pocket:
                PocketHandleGlyph()
                    .frame(width: 15, height: 13)
            case .none:
                EmptyView()
            }
        }
    }
}

private struct PocketHandleGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let dotSize = min(size.width, size.height) * 0.22

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: dotSize, height: dotSize)
                    .position(x: size.width / 2, y: dotSize * 0.82)

                PocketCupShape()
                    .stroke(
                        Color.white.opacity(0.72),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }
}

private struct PocketCupShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topY = rect.minY + rect.height * 0.48
        let bottomY = rect.minY + rect.height * 0.82
        let leftX = rect.minX + rect.width * 0.18
        let rightX = rect.maxX - rect.width * 0.18
        let centerX = rect.midX
        path.move(to: CGPoint(x: leftX, y: topY))
        path.addLine(to: CGPoint(x: leftX, y: bottomY - 1))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: bottomY - 1),
            control: CGPoint(x: centerX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightX, y: topY))

        return path
    }
}
