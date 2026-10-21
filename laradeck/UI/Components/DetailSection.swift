import SwiftUI

/// A titled card used by the detail pages: headline + optional trailing control, rows in a
/// card, optional footnote. Rows use `.detailRow()` for padding and separators.
struct DetailSection<Content: View, Accessory: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, footer: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                accessory()
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .clipShape(RoundedRectangle(cornerRadius: LaradeckTheme.cardCornerRadius, style: .continuous))
            .laradeckCard()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// Row inside a `DetailSection`: standard padding and a hairline below.
    func detailRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Divider().padding(.leading, 14)
            }
    }
}
