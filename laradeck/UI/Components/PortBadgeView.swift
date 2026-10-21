import SwiftUI

/// One pill per port, e.g. `:80` `:5173`.
struct PortBadgeView: View {
    let ports: [Int]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ports, id: \.self) { port in
                Text(verbatim: ":\(port)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.12), in: Capsule())
            }
        }
    }
}

enum ProcessRowLayoutMetrics {
    static let statusColumnWidth: CGFloat = 92
    static let controlsColumnWidth: CGFloat = 72
}
