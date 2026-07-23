import Carbon.HIToolbox
import AppKit

/// GLOBAL keyboard shortcut (works even when the app is not in the foreground),
/// using the Carbon RegisterEventHotKey API. Does not require Accessibility permissions.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private let callback: () -> Void

    /// Static map so the C callback (which can't capture) can locate the instance.
    ///
    /// WEAK on purpose, and it is load-bearing twice over:
    ///  1. A strong map keeps a HotKey alive after its owner drops it, so `deinit` — and with it
    ///     `UnregisterEventHotKey` — never runs. The shortcut then stays registered with Carbon for
    ///     the rest of the session and keeps SWALLOWING that key system-wide. For a session-scoped
    ///     Esc that means Esc stops working in every other app until Klip quits.
    ///  2. A strong map also crashes on re-registration: `instances[id] = self` releases the old
    ///     instance *during* the dictionary's mutation, its deinit reads `instances[id]` back, and
    ///     Swift traps on the overlapping exclusive access (EXC_CRASH in HotKey.deinit).
    /// Boxing the weak reference keeps both problems away: replacing an entry only releases a box,
    /// and deinit never touches the map at all.
    private final class WeakBox {
        weak var value: HotKey?
        init(_ value: HotKey) { self.value = value }
    }
    private static var instances: [UInt32: WeakBox] = [:]
    private static var handlerInstalled = false

    /// - Parameters:
    ///   - keyCode: virtual key code (e.g. kVK_ANSI_V).
    ///   - modifiers: Carbon combination (e.g. cmdKey | shiftKey).
    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, callback: @escaping () -> Void) {
        self.id = id
        self.callback = callback
        HotKey.instances[id] = WeakBox(self)

        HotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x50415354), id: id) // 'PAST'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            HotKey.instances[id] = nil   // box only: self is still on the stack, no deinit here
            return nil
        }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let instance = HotKey.instances[hkID.id]?.value {
                DispatchQueue.main.async { instance.callback() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    /// Hot-reloads with a new combination, reusing the id and callback.
    /// The already-installed global handler stays valid; it is not reinstalled.
    @discardableResult
    func reRegister(keyCode: UInt32, modifiers: UInt32) -> Bool {
        // Register the NEW one in a temporary ref; only release the old one if it succeeded,
        // so we don't end up without a shortcut if the combination collides.
        let hotKeyID = EventHotKeyID(signature: OSType(0x50415354), id: id) // 'PAST'
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        if let old = hotKeyRef { UnregisterEventHotKey(old) }
        hotKeyRef = newRef
        return true
    }

    deinit {
        // ONLY the Carbon unregister. Deliberately no `instances` access: the map is weak, so our
        // slot's value nils itself, and touching the map here is exactly what trapped when a
        // replacement assignment was the thing releasing us (see the note on `instances`).
        // The Carbon event handler is a single process-lifetime global (installHandlerIfNeeded)
        // shared by every instance — intentionally not removed per-instance.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }
}
