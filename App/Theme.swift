import AppKit
import SwiftUI

/// Black or paper white, one ink, hairlines, mono captions, and a single color that only
/// ever marks where the cursor stumbles.
enum Theme {
    private static let paperLight: UInt32 = 0xF6F6F3, paperDark: UInt32 = 0x000000
    static let paper = dynamic(light: paperLight, dark: paperDark)
    static let ink = dynamic(light: 0x111111, dark: 0xF2F2F2)
    static let quiet = dynamic(light: 0x7A7A73, dark: 0x7C7C7C)
    static let hairline = dynamic(light: 0xDCDCD5, dark: 0x262626)
    static let signal = dynamic(light: 0xE4530A, dark: 0xFF6A2A)

    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
    static let title = Font.system(size: 32, weight: .medium)
    static let body = Font.system(size: 14)

    /// The paper of one look, for drawing outside SwiftUI.
    static func paper(dark: Bool) -> CGColor {
        let hex = dark ? paperDark : paperLight
        return CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
