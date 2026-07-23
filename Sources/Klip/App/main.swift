import AppKit

// Entry point. Accessory app (no Dock icon); lives in the menu bar.
// Top-level code is nonisolated; the whole launch runs on the main thread, so assert MainActor for the
// @MainActor AppDelegate. `delegate` is retained here for the app's lifetime (NSApplication.delegate is weak).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(ProcessInfo.processInfo.environment["KLIP_REGULAR"] == nil ? .accessory : .regular)
    app.run()
}
