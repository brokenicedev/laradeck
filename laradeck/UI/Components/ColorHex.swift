import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        var rgbValue: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255
        let b = Double(rgbValue & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Best-effort RGB hex (opacity dropped) — good enough for a stored avatar color.
    var hexString: String {
        let resolved = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let r = Int((resolved.redComponent * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
