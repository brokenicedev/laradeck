import SwiftUI

extension View {
    /// The "Close" (×) toolbar button project dashboards have, for any detail page.
    func detailCloseButton(help: String, action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: action) {
                    Label("Close", systemImage: "xmark")
                }
                .help(help)
            }
        }
    }
}
