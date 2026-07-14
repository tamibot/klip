import AppKit
import SwiftUI

/// Press feedback for custom (`.plain`/`.borderless`) buttons that don't get AppKit's native
/// press dip. Apple's first fluid-interface principle: respond on press-DOWN, instantly. The dip
/// rides a critically-damped spring (no overshoot) so it feels physical, not scripted. Respects
/// Reduce Motion (the spring degrades to an instant state change there automatically).
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.snappy(duration: 0.18, extraBounce: 0), value: configuration.isPressed)
    }
}

/// Native macOS "glass" chrome for auxiliary windows (Welcome, Guide, Upload, Preferences):
/// a behind-window translucent material running edge to edge under a transparent titlebar,
/// so they match the history panel / HUD look instead of a flat opaque window.
@MainActor
enum Glass {
    /// Replaces the window's content view with a glass background hosting `root`, and makes
    /// the titlebar transparent over it. SwiftUI content keeps respecting the titlebar via
    /// the hosting view's safe area.
    static func install<V: View>(_ root: V, in window: NSWindow,
                                 material: NSVisualEffectView.Material = .underWindowBackground) {
        let fx = NSVisualEffectView()
        fx.material = material
        fx.blendingMode = .behindWindow
        fx.state = .followsWindowActiveState
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.contentView = fx
    }
}
