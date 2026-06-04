import AppKit
import Foundation

/// Notch geometry detection for built-in displays of M1 Pro/Max + every newer notched MacBook.
///
/// Strategy (per architecture.md):
/// 1. `safeAreaInsets.top > 0` → notch present.
/// 2. Width derived from `auxiliaryTopLeftArea` + `auxiliaryTopRightArea` exactly (public macOS 12+ API).
/// 3. Fallback 200×32 centered for unknown/non-notched displays.
public enum NotchGeometry {

    /// Returns notch rect in **screen coordinates** (origin at bottom-left, y growing up — AppKit convention),
    /// or `nil` if this screen has no notch.
    public static func notchRect(for screen: NSScreen) -> CGRect? {
        let insetTop = screen.safeAreaInsets.top
        guard insetTop > 0 else { return nil }
        let width = exactNotchWidth(for: screen) ?? 200
        let x = screen.frame.midX - (width / 2)
        let y = screen.frame.maxY - insetTop
        return CGRect(x: x, y: y, width: width, height: insetTop)
    }

    /// Virtual notch rect for non-notched displays — 200×32 anchored top-center.
    /// Used when Stan is on an older Mac or an external-only setup where we still want
    /// to render Notchi as a centered top-of-screen widget.
    public static func virtualNotchRect(for screen: NSScreen) -> CGRect {
        let width: CGFloat = 200
        let height: CGFloat = 32
        let x = screen.frame.midX - (width / 2)
        let y = screen.frame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The screen Notchi should render on:
    ///   1. First built-in screen with a real notch
    ///   2. else first screen whose `localizedName` contains "Built-in"
    ///   3. else `nil` (caller should hide window — clamshell mode)
    public static func preferredScreen(among screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        if let s = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return s
        }
        if let s = screens.first(where: { $0.localizedName.contains("Built-in") }) {
            return s
        }
        return nil
    }

    /// Computes notch width by subtracting the menu-bar safe areas from total screen width.
    /// `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are public macOS 12+ API.
    private static func exactNotchWidth(for screen: NSScreen) -> CGFloat? {
        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea
        else { return nil }
        let width = screen.frame.width - leftArea.width - rightArea.width
        return width > 0 ? width : nil
    }
}
