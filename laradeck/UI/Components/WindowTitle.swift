import SwiftUI

extension View {
    /// Window title for a detail screen: "Laradeck — <title>", so Mission Control and the
    /// Window menu show which app the window belongs to.
    func laradeckTitle(_ title: String) -> some View {
        navigationTitle("Laradeck — \(title)")
    }
}
