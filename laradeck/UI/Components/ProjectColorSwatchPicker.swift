import SwiftUI

/// Dropdown color control: palette swatches + optional HEX — no system `ColorPicker` / `NSColorPanel`.
struct ProjectColorSwatchPicker: View {
    @Binding var color: Color

    @State private var isExpanded = false
    @State private var hexDraft = ""

    private var selectedHex: String {
        color.hexString.uppercased()
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        LabeledContent("Background color") {
            Button {
                hexDraft = selectedHex
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        }

                    Text(verbatim: "#\(selectedHex)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                popoverContent
            }
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Palette")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ProjectColorPalette.hexValues, id: \.self) { hex in
                    let isSelected = selectedHex == hex.uppercased()
                    Button {
                        color = Color(hex: hex)
                        hexDraft = hex.uppercased()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.primary.opacity(0.55) : Color.primary.opacity(0.12),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .help("#\(hex)")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("HEX")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text("#")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))

                    TextField("FB563D", text: $hexDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: hexDraft) { _, newValue in
                            hexDraft = Self.sanitizedHex(newValue)
                            if let applied = Self.color(fromHex: hexDraft) {
                                color = applied
                            }
                        }

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Self.color(fromHex: hexDraft) ?? color)
                        .frame(width: 28, height: 28)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                        }
                }

                Text("6-digit hex (e.g. 3B82F6)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    /// Keep only hex digits, max 6, uppercased.
    private static func sanitizedHex(_ raw: String) -> String {
        let filtered = raw
            .uppercased()
            .filter { $0.isHexDigit }
        return String(filtered.prefix(6))
    }

    private static func color(fromHex hex: String) -> Color? {
        let trimmed = sanitizedHex(hex)
        guard trimmed.count == 6 else { return nil }
        return Color(hex: trimmed)
    }
}
