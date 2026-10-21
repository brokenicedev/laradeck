import SwiftUI

/// Official Laravel mark from the project asset catalog (#FF2D20 vector).
struct LaravelLogoView: View {
    var size: CGFloat = 16

    var body: some View {
        Image("LaravelLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("Laravel")
    }
}
