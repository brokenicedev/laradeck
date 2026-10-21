import SwiftUI

/// Drop-in replacement for menu-style `Picker` that avoids AppKit ViewBridge popups and SwiftUI
/// `Menu` item visibility bugs on recent macOS versions.
struct MenuPicker<SelectionValue: Hashable>: View {
    private let label: String?
    @Binding private var selection: SelectionValue
    private let options: [(SelectionValue, String)]
    private var width: CGFloat?

    @State private var isExpanded = false

    init(
        _ label: String? = nil,
        selection: Binding<SelectionValue>,
        width: CGFloat? = nil,
        options: [(SelectionValue, String)]
    ) {
        self.label = label
        self._selection = selection
        self.width = width
        self.options = options
    }

    private var selectedTitle: String {
        options.first { $0.0 == selection }?.1 ?? ""
    }

    var body: some View {
        if let label {
            LabeledContent(label) { pickerControl }
        } else {
            pickerControl
        }
    }

    private var pickerControl: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selectedTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
            .modifier(OptionalWidth(width: width))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
            pickerList
        }
    }

    private var pickerList: some View {
        VStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button {
                    selection = value
                    isExpanded = false
                } label: {
                    HStack {
                        Text(title)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if value == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if value != options.last?.0 {
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: width ?? 180)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OptionalWidth: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
