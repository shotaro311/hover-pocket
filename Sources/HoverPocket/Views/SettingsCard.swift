import SwiftUI

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.secondary.opacity(0.12), lineWidth: 1)
            }
    }
}

struct SettingsDetails<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
        }
    }
}
