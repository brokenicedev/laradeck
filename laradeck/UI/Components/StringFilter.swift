import SwiftUI

/// Compact search field for filtering a list in place (magnifying glass + clear button),
/// styled like the system search field.
struct FilterField: View {
    let prompt: String
    @Binding var text: String
    var maxWidth: CGFloat? = 280

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .frame(maxWidth: maxWidth)
    }
}

extension String {
    /// Case- and diacritic-insensitive match used by the filters; empty query matches all.
    func matchesFilter(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
