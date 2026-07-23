import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Result of a capture: the captured screen, its pixel bitmap, and the scale factor.
struct DisplayShot {
    let screen: NSScreen
    let cgImage: CGImage
    let scale: CGFloat
}

enum CaptureError: Error { case noDisplay, noPermission }

/// Screen capture with ScreenCaptureKit (macOS 14+). Replaces `CGDisplayCreateImage`
/// (deprecated). Strategy: capture ONLY the display that contains the cursor — this avoids the
/// classic multi-monitor coordinate bugs and matches the real use case (you select where you are).
enum ScreenCapturer {

    /// Has the user already granted Screen Recording permission? (does not trigger the prompt)
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt (only once). Returns whether it ended up granted.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Warms up the capture subsystem so the first real shot has no visible latency.
    static func warmUp() {
        Task.detached(priority: .utility) {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
    }

    /// Captures the display that contains `point` (global Cocoa coordinates, bottom-left origin).
    static func captureDisplay(containing point: NSPoint) async throws -> DisplayShot {
        guard hasPermission() else { throw CaptureError.noPermission }

        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { throw CaptureError.noDisplay }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scd = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplay
        }

        // Exclude Klip's own windows (panel/overlay) so they don't appear in the capture.
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: scd, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        // Physical pixels = points × scale (correct on Retina).
        config.width  = Int(screen.frame.width  * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        config.scalesToFit = false

        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return DisplayShot(screen: screen, cgImage: cg, scale: screen.backingScaleFactor)
    }
}

extension NSScreen {
    /// CGDirectDisplayID of this screen (to match against SCDisplay).
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
