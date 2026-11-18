import SwiftUI
import AppKit

/// The app's own dark look: near-black graphite surfaces with an amber accent, regardless of the
/// system appearance. Text uses the system primary/secondary colours on top of these.
enum Theme {
    static let bg=Color(red:0.039,green:0.043,blue:0.051)        // #0A0B0D window
    static let sidebar=Color(red:0.051,green:0.055,blue:0.063)   // #0D0E10
    static let panel=Color(red:0.075,green:0.078,blue:0.09)      // #131417 cards and panels
    static let raised=Color(red:0.11,green:0.114,blue:0.129)     // #1C1D21 popovers, toast
    static let line=Color.white.opacity(0.08)
    static let accent=Color(red:0.914,green:0.714,blue:0.353)    // #E9B65A
    static let nsBackground=NSColor(srgbRed:0.039,green:0.043,blue:0.051,alpha:1)
}
