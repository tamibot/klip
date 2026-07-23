import AppKit
import Carbon.HIToolbox
import Testing
@testable import Klip

/// The eight global shortcuts are described by FOUR hand-written tables that no compiler ties together:
/// `ShortcutKind.carbonID`, `ShortcutKind.combo` (key paths), `ShortcutKind.defaultCombo`, and the
/// `d.register(defaults:)` block in `Settings.init`. Every one of them is a `switch` or a literal list
/// edited by hand each time a shortcut is added, and every mistake in them compiles cleanly.
///
/// None of the runtime machinery catches a table mistake either: `deduplicateShortcuts`, the
/// setupHotKeys recovery ladder and `collidesWithOtherShortcut` all reason about COMBOS — never about
/// ids, key paths, or registered defaults. So a duplicated id or a copy-pasted key path is silent at
/// build time, silent at launch, and shows up only as a shortcut that fires the wrong feature or no
/// feature at all. That is the same failure shape as the past no-menu-bar bug, on the same launch path.
///
/// Everything here is pure table data: no NSApplication, no Carbon registration, no disk. The one
/// exception is documented on `registeredDefaultsMatchTheDeclaredDefaults`.
@Suite("Shortcut table")
struct ShortcutTableTests {

    // MARK: - Carbon ids

    /// `HotKey` keys its instance map by carbonID (`HotKey.instances[id] = WeakBox(self)`), so two kinds
    /// sharing an id is a silent hijack: the second registration overwrites the first box and kind A's
    /// combo starts running kind B's action. If the two ALSO share a combo, the second init fails with
    /// eventHotKeyExistsErr and its failure path runs `instances[id] = nil`, wiping the FIRST kind's box
    /// too — both shortcuts dead for the whole session, with no alert (the recovery path in setupHotKeys
    /// only fires on `hotKeys[kind] == nil`, which is not what happens here).
    @Test("no two shortcut kinds share a Carbon registration id")
    func carbonIDsAreUnique() {
        let ids = ShortcutKind.allCases.map(\.carbonID)
        #expect(Set(ids).count == ids.count, "duplicate carbonID in \(ids)")
        // Tripwire, not a behaviour: whoever adds a ninth shortcut has to open this file, which is where
        // the reserved-id note below lives. (Deliberately not "every case is in allCases" — CaseIterable
        // is synthesized, so that can never fail.)
        #expect(ShortcutKind.allCases.count == 8)
    }

    /// Id 9 belongs to the scroll-capture session Esc registered ad hoc in AppDelegate
    /// (`HotKey(keyCode: kVK_Escape, modifiers: 0, id: 9)`, in the scrolling-capture handler). A ninth
    /// ShortcutKind numbered 9 would have its WeakBox replaced by that Esc; when the scroll session ends
    /// the Esc instance deinits, the weak value nils out, and that shortcut is dead until relaunch —
    /// while the Esc itself may fail to register, leaving a scroll session nothing can cancel.
    @Test("id 9 stays reserved for the scroll-capture Esc")
    func idNineIsNotUsedByAnyKind() {
        #expect(ShortcutKind.allCases.contains { $0.carbonID == 9 } == false)
    }

    // MARK: - Storage key paths

    /// `ShortcutKind.combo` is eight hand-written `return \.xCombo` lines. A copy-paste there (two kinds
    /// returning `\.screenRecCombo`) compiles, and then two Preferences rows edit ONE stored property:
    /// `collidesWithOtherShortcut` reports a clash for the twin on every edit so `apply` reverts instantly,
    /// and dedup sees a duplicate it can never break because moving one moves the other. The affected
    /// shortcut can then never be set — permanently, across relaunches.
    @Test("each shortcut kind persists to its own Settings property")
    func comboKeyPathsAreDistinct() {
        let paths = ShortcutKind.allCases.map(\.combo)
        #expect(Set(paths).count == paths.count, "two kinds share a Settings key path")
    }

    // MARK: - Defaults

    /// The only check that spans all three copies of the same eight facts: the `KeyCombo.default*Combo`
    /// constants, the `K.keyCode2…keyCode8` key strings, and the `d.register(defaults:)` block — three
    /// hand-copied tables in one file, 200+ lines apart, with no compiler link between them. A swapped
    /// key string ships silently: setupHotKeys compares the persisted combo against `kind.defaultCombo`
    /// and, on any registration failure, OVERWRITES the persisted value, so a fresh install can boot on a
    /// shortcut that no documentation mentions.
    ///
    /// READ-ONLY on purpose, and it must stay that way. Touching `Settings.shared` from a test constructs
    /// the singleton against the test runner's own defaults domain (Bundle.main is nil under
    /// swiftpm-testing-helper, so this is NOT Klip's io.github.tamibot.klip). Reading is inert; ASSIGNING would
    /// fire the `@Published` didSet, persist that value into the runner's domain, and break this test on
    /// the NEXT run — on that machine only. Never assign to Settings.shared from a test.
    @Test("every shortcut's registered UserDefaults default is the combo the table declares")
    func registeredDefaultsMatchTheDeclaredDefaults() {
        let settings = Settings.shared
        for kind in ShortcutKind.allCases {
            #expect(settings[keyPath: kind.combo] == kind.defaultCombo,
                    "\(kind) boots on \(settings[keyPath: kind.combo].displayString) but declares \(kind.defaultCombo.displayString)")
        }
    }

    /// Eight letters (E R D F O M V S) on ⌥⇧, declared as eight separate `static let`s — nothing catches a
    /// duplicate. Dedup would then take its ugly branch (`taken.contains(kind.defaultCombo)`) and relocate
    /// the later kind to the first free suggestion, ⌥⇧Y, which is documented nowhere: the user presses what
    /// the guide shows, nothing happens, and only the menu-bar label tells the truth.
    ///
    /// Pairwise rather than a Set because `KeyCombo` is Equatable and not Hashable — adding Hashable to
    /// production just to shorten a test is the wrong trade.
    @Test("the eight default combos are all different from each other")
    func defaultCombosArePairwiseDistinct() {
        let kinds = ShortcutKind.allCases
        for i in kinds.indices {
            for j in kinds.indices where j > i {
                #expect(kinds[i].defaultCombo != kinds[j].defaultCombo,
                        "\(kinds[i]) and \(kinds[j]) both default to \(kinds[i].defaultCombo.displayString)")
            }
        }
    }

    /// A duplicated suggestion is worse than wasted: the recovery loops walk `suggestions` in order and
    /// would hand the same combo out twice, and `FilteredHotKeyField` renders the list with
    /// `id: \.displayString`, so a repeat is a duplicate-identity SwiftUI ForEach.
    @Test("the suggested combos are all different from each other")
    func suggestionsArePairwiseDistinct() {
        let s = KeyCombo.suggestions
        for i in s.indices {
            for j in s.indices where j > i {
                #expect(s[i] != s[j], "suggestion \(i) and \(j) are both \(s[i].displayString)")
            }
        }
        // Same list, seen through the Preferences dropdown's identity function.
        #expect(Set(s.map(\.displayString)).count == s.count)
    }

    /// The rule `RecorderNSView.keyDown` enforces on the USER — `carbon & ~UInt32(shiftKey) != 0` — is
    /// enforced nowhere on the combos we pick FOR them, and it is the worst failure in this area.
    /// `ensureLiveRegistered` and the setupHotKeys suggestion loop pass candidates straight to
    /// RegisterEventHotKey without consulting `isValid`. A zero-modifier combo does not get rejected — Klip
    /// itself registers bare Esc that way — it SUCCEEDS and swallows that key in every application on the
    /// Mac until Klip quits. A Shift-only combo hijacks the shifted letter: the user can no longer type a
    /// capital E anywhere.
    @Test("no combo Klip ships can be registered on Shift alone, or on no modifier at all")
    func shippedCombosAlwaysCarryANonShiftModifier() {
        for kind in ShortcutKind.allCases {
            #expect(kind.defaultCombo.carbonModifiers & ~UInt32(shiftKey) != 0,
                    "\(kind)'s default would hijack a bare or shifted key system-wide")
        }
        for combo in KeyCombo.suggestions {
            #expect(combo.carbonModifiers & ~UInt32(shiftKey) != 0,
                    "suggestion \(combo.displayString) would hijack a bare or shifted key system-wide")
        }
        // `isValid` is the weaker half of the same rule and the only part of it the code states out loud.
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: 0).isValid == false)
    }

    // MARK: - Cocoa ⇄ Carbon modifier bridge

    /// `cocoaToCarbonModifiers` and `KeyCombo.cocoaModifiers` are two hand-written if-ladders that must
    /// stay mirror images: one turns what the user PRESSES in the recorder into what gets registered with
    /// Carbon, the other turns what is registered into what the menu, the guide and the welcome screen
    /// TELL the user to press. Drift between them is silent in both directions — the app advertises one
    /// modifier set and listens for another, and pressing what it says does nothing, with no error.
    @Test("every modifier combination survives the Cocoa/Carbon round trip unchanged")
    func modifierRoundTripIsLossless() {
        let bits = [UInt32(cmdKey), UInt32(shiftKey), UInt32(optionKey), UInt32(controlKey)]
        for subset in 0..<(1 << bits.count) {
            var carbon: UInt32 = 0
            for (i, bit) in bits.enumerated() where subset & (1 << i) != 0 { carbon |= bit }
            let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: carbon)
            #expect(cocoaToCarbonModifiers(combo.cocoaModifiers) == carbon,
                    "round trip lost bits for carbon modifiers \(carbon)")
        }
    }

    /// Load-bearing, not incidental: the recorder masks the event with `.deviceIndependentFlagsMask`,
    /// which still contains `.capsLock` and `.function`. If either ever leaked into the carbon value, the
    /// recorded shortcut could never fire — RegisterEventHotKey would be waiting for a modifier set the
    /// keyboard cannot reproduce.
    @Test("modifier flags Carbon has no bit for are dropped, not smuggled through")
    func unmappedCocoaFlagsAreDropped() {
        #expect(cocoaToCarbonModifiers([.command, .capsLock, .function]) == UInt32(cmdKey))
        #expect(cocoaToCarbonModifiers([]) == 0)
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: 0).cocoaModifiers.isEmpty)
    }

    // MARK: - How the shortcut is displayed

    /// Two separate traps in four lines. (1) The key equivalent must be LOWERCASE: an uppercase one makes
    /// AppKit draw an implicit Shift, so an ⌥⇧E row would read ⌥⇧⇧E. (2) ⌥Space is a shipped suggestion,
    /// and `keyName` returns "Space" for it — five characters — so without the special case it would fall
    /// out of the single-character branch and lose its native key equivalent.
    @Test("a menu key equivalent is the lowercase key, and Space is a literal space")
    func menuKeyEquivalentIsLowercased() {
        #expect(KeyCombo.defaultCombo.menuKeyEquivalent == "e")
        #expect(KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey)).menuKeyEquivalent == " ")
    }

    /// FIXED BUG. `keyName` renders Return/Tab/Escape/Delete as GLYPHS (↩ ⇥ ⎋ ⌫), each exactly one
    /// Character, so the old `name.count == 1` test handed the glyph itself to NSMenuItem as its key
    /// equivalent. The row still LOOKED right — AppKit draws whatever character it is given — but no
    /// keypress can ever match a glyph, so the in-menu shortcut was dead, and the documented title-suffix
    /// fallback never ran either. Reachable: ⌥↩ passes both `isValid` and the recorder's non-Shift rule.
    /// AppKit matches these keys by their control characters; those are what the property returns now.
    @Test("Return maps to the control character AppKit can match, not to its glyph")
    func nonTypeableKeysUseTheirControlCharacter() {
        #expect(KeyCombo(keyCode: UInt32(kVK_Return), carbonModifiers: UInt32(optionKey)).menuKeyEquivalent == "\r")
        #expect(KeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey)).menuKeyEquivalent == "\t")
        // Still drawn as glyphs in the title/display string — only the key equivalent changed.
        #expect(KeyCombo(keyCode: UInt32(kVK_Return), carbonModifiers: UInt32(optionKey)).displayString == "⌥↩")
    }

    /// The branch `addShortcutItem` falls back to: an empty key equivalent makes it append the display
    /// string to the item title instead, which is the only reason the shortcut stays discoverable at all.
    /// User-reachable — ⌥F1 records fine, and F1 is not in `keyName`'s map.
    @Test("a key with no name falls back to an empty equivalent and a hex display string")
    func unknownKeyFallsBackToTheTitleSuffix() {
        let f1 = KeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: UInt32(optionKey))
        #expect(f1.menuKeyEquivalent == "")
        #expect(f1.displayString == "⌥Key 7A")
    }

    /// macOS draws modifiers in one canonical order — ⌃⌥⇧⌘ — everywhere. `displayString` is the single
    /// place Klip builds that string, and it feeds the menu, GuideView, WelcomeView and HistoryView.
    @Test("display string lists modifiers in the canonical macOS order")
    func displayStringUsesCanonicalModifierOrder() {
        let all = KeyCombo(keyCode: UInt32(kVK_ANSI_A),
                           carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(all.displayString == "⌃⌥⇧⌘A")
    }
}
