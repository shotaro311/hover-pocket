import SwiftUI

struct HoverPillView: View {
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
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
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
}
