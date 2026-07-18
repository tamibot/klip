# UI Polish Program — 23 curated improvements

Approved 2026-07-17. Produced by a multi-lens brainstorm (8 lenses, 78 raw ideas) grounded in a
full read of every UI surface plus DESIGN.md; curated down to the ideas that survive the design
record and the shipped-polish history. All file:line references verified at curation time against
`9b4b43b`.

Binding constraints for every item: DESIGN.md rules (especially R3 no stacked materials, R13 soft
scroll edges, the text-never-moves rule), Apple-native restraint, Reduce Motion honored on any new
animation, new user-facing/accessibility strings localized in all 8 L10n tables.

## Quick wins (S)

1. **Welcome window fix** — window is 440×580 but content is 440×700 (CTA can clip); size window
   from the hosting view, and make "Get started" open the panel instead of leaving the app invisible.
2. **Severity-aware toasts** — ToastHUD gains `.failure` style (orange `exclamationmark.triangle.fill`,
   no bounce); flip capture-failed, no-text, hotkey-in-use, upload-skipped sites; give exportBackup
   its own string instead of reusing `toast.imageSaved`.
3. **VoiceOver outcome announcements** — announce toast title+detail; describe the toast glyph;
   spoken "Copied" twin for the menu-bar flash; longer actionable-toast lifetime under VO.
4. **Per-tool editor cursors** — crosshair/I-beam/arrow by tool; open/closed hand over draggable
   annotations in select mode.
5. **Copy tick generation counter** — row copy button answers every click (bool+timer → Int generation).
6. **Menu-bar button pass** — record light survives copy flashes; 0.12s crossfade on icon swaps;
   `highlight(true/false)` while the panel is open. Contract: AppDelegate exposes
   `setStatusItemHighlighted(_:)`; PanelController calls it from show/hide.
7. **Link-row search highlighting** — the computed highlight is currently discarded; render it.
8. **One optical left edge** — image-card padding 10→12; OCR box loses its extra horizontal padding;
   name the gutter/inset constants.
9. **Batch bar off the second material** — replace `.ultraThinMaterial` + Divider with a
   vibrancy-safe fill + mirrored scroll-edge gradient (R3/R13 compliance).
10. **Editor dark-mode canvas** — appearance-adaptive checkerboard (rebuild pattern on appearance
    change); toolbar follows window active state; delete the stray machine-translation artifact.
11. **One outcome voice** — route remaining raw `NSSound.beep()` sites through SoundFX; give
    exportSelectedZip its `.save` cue; success cue beside the API-key saved checkmark.
12. **32pt editor toolbar grid** — all chips pinned 32×32; retire the stray 30pt constant; name the
    bar height once.

## Medium bets (M)

1. **VoiceOver row model** — composed labels (credentials always masked), traits, day headers as
   headers, batch checkbox as toggle, hover-only actions mirrored as accessibility custom actions.
2. **Motion table** — `Motion` enum in Glass.swift (appear .13 / dismiss .12 / state .15 / morph .18 /
   snappy spring) with one Reduce Motion gate; migrate scattered literals; gate the five verified
   ungated animations (press dip, chip swap, copy bounce, HoverToolButton, meeting HUD morph).
3. **Keyboard parity in the panel** — action strip follows arrow selection (hasNavigated flag);
   batch mode answers arrows/Return; context menus display existing shortcuts.
4. **Batch mechanics** — Cmd-click enters batch, Shift-click ranges, "Select all (N)" in the batch bar.
5. **Drag out of the panel** — text/link/image/voice providers (credentials excluded); panel
   survives the drag session; haptic on lift.
6. **Gradient-lit specular rim** — CAGradientLayer masked to a 1pt stroke, oriented to the sheen's
   light direction; closes DESIGN.md checklist item 5 on every floating surface.
7. **One modifier language** — Shift-square/45°, Option-from-center on the canvas (ported from the
   overlay); Option-center added to the overlay; hint pill teaches all three; device-pixel snapping.
8. **Soft-escape ladder + nudge** — Esc: color panel → deselect → discard confirm; arrow-key nudge
   1pt/10pt with coalesced undo.
9. **KeyChip** — one shared shortcut-chip component (Guide's recipe) adopted in kbdHint, Welcome,
   and the empty state (plus the missing capture hint).
10. **Zoom story** — live percentage during pinch, animated reset, ⌘+/−/0, Space-hold panning.

## Big swing (L)

1. **Resize handles on selected annotations** — corner/edge/endpoint handles; rect-family two-point
   rescale, line/arrow endpoints, text corner→fontSize; one undo per resize; selection box restyled
   in the overlay's two-stroke marquee dialect.

## Build plan

Sequential waves of parallel agents with disjoint file sets; compile+test+commit between waves;
adversarial review of the full diff at the end.

- Wave 1 (parallel): editor-S (QW 4/10/12) · toast-shell (QW 2/3/6/11) · panel-S (QW 1/5/7/8/9 + zip cue)
- Wave 2 (parallel): editor-M (MB 7/8/10) · panel-M (MB 1/3/4/5)
- Wave 3 (parallel): materials (MB 6/9) · resize handles (BS 1)
- Wave 4: motion table sweep (MB 2) — last, because it touches every surface.
