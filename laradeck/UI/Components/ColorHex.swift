import SwiftUI
import AppKit

extension Color {
    /// Accepts rgb, rgba, rrggbb and rrggbbaa, with or without a leading `#`.
    /// Unparsable input falls back to opaque black.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        if s.count == 6 { s += "ff" }
        let v = (s.count == 8 ? UInt64(s, radix: 16) : nil) ?? 0x000000ff
        self.init(.sRGB,
                  red: Double((v >> 24) & 0xff) / 255,
                  green: Double((v >> 16) & 0xff) / 255,
                  blue: Double((v >> 8) & 0xff) / 255,
                  opacity: Double(v & 0xff) / 255)
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
