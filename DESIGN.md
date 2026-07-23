# Klip — Design Notes: the glass

Why Klip's floating surfaces look the way they do, and how to keep them right. Target floor macOS 14
(no Liquid Glass API). The operational recipe lives in `Sources/Klip/UI/Glass.swift`; this is the *why*
behind it. Read this before touching any panel, popover, or window material.

---

## 1. What Apple's glass actually IS

### The vibrancy era (macOS 10.10–14) — light **scattering**

A material is not a blur. Apple's own definition ([HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)):

> "Materials help visually separate foreground elements, such as text and controls, from background elements... **By allowing color to pass through from background to foreground**, a material establishes visual hierarchy to help people more easily retain a sense of place."

The named mechanism is *color passing through*, not blur. The implementation is a stack: saturation boost → blur → luminance clamp → vibrant foreground. `NSVisualEffectView` picks these recipes semantically (`.popover`, `.menu`, `.hudWindow`, …) out of CoreUI `.car` asset catalogs — which is why the real numbers are odd values like `0.9647`, not round ones ([Groth's reverse-engineering](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview)).

**Vibrancy** = drawing foreground content in tinted greys mapped against the material, not in fixed colors. It is opt-in and must be tested.

### The Liquid Glass era (26 / Tahoe) — light **bending**

The single load-bearing sentence, verbatim from [WWDC25 219 "Meet Liquid Glass"](https://developer.apple.com/videos/play/wwdc2025/219/):

> "Where as previous materials **scattered** light, this new set of materials dynamically **bends, shapes, and concentrates** light in real time."

And the mechanism has a name:

> "The primary way Liquid Glass visually defines itself is through something called **Lensing**."

Lensing lives at the **edges**. The interior stays comparatively clear. [Apple Newsroom](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/) splits it into two optical channels: elements "**refract** the content behind them — while **reflecting** content and the user's wallpaper from around them."

Three layers compose it (Apple's naming, also [CSS-Tricks](https://css-tricks.com/getting-clarity-on-apples-liquid-glass/)): **Highlight** (specular response to geometry), **Shadow** (content-aware separation), **Illumination** (interactive inner glow).

### The delta in one table

| | Vibrancy (11–14) | Liquid Glass (26) |
|---|---|---|
| Optics | scatter (blur) | bend (refract/lens) |
| Appearance | fixed light or dark | continuously adapts to backdrop |
| Shadow | static drop shadow | opacity rises over text, falls over solid light |
| Where the effect lives | whole surface | the rim/bezel |
| Transition | fade | "materialize" by modulating lensing |

### And where Apple went next — the walkback matters

macOS 27 "Golden Gate" (WWDC26) **reduced** transparency: a user-facing translucency slider, higher baseline opacity, and — the tell — Apple **added "darkened edges and brighter specular highlights"** to restore depth and separation ([MacRumors](https://www.macrumors.com/2026/06/09/macos-golden-gate-liquid-glass/)).

**The lesson, and this is the whole brief in one line: glass is defined by its rim, not by how much shows through.** Spend your effort on the edge. Be conservative with body transparency. Klip's recent commits ("most-translucent light material", "light glossy Dock-style glass") are pushing the exact direction Apple itself reversed.

---

## 2. The rules

**R1 — Glass is the navigation layer only.** ([WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/)) "You may be tempted to use Liquid Glass everywhere but it is best reserved for the navigation layer that floats above the content of your app." → **Klip's panel surface is glass. The clipboard list is not.**

**R2 — Content stays in the content layer.** "Consider this tableview: making it Liquid Glass would make it compete with other elements and muddy the hierarchy." A clipboard list *is* a tableview.

**R3 — Never glass on glass.** "always avoid glass on glass... When placing elements on top of Liquid Glass, avoid applying the material to both layers. Instead, use **fills, transparency, and vibrancy** for the top elements to make them feel like a thin overlay that is part of the material." → **Rows and buttons inside the Klip panel get fills + vibrancy. Never a second `NSVisualEffectView`.** This is the most-violated rule in third-party clones.

**R4 — Regular, never Clear.** Regular "provides legibility regardless of context. It works in any size, over any content." Clear "does not have adaptive behaviors" and requires three conditions, *all* of which must hold: over media-rich content, content tolerates a dimming layer, and the overlaid content is bold and bright. **Klip meets none.** Also: "They should never be mixed."

**R5 — Choose semantically, never by looks.** ([HIG](https://developer.apple.com/design/human-interface-guidelines/materials)) "**Avoid selecting a material or effect based on the apparent color it imparts to your interface**, because system settings can change its appearance and behavior. Instead, match the material or vibrancy style to your specific use case." Picking a material because it looks glossiest is the documented mistake, by name.

**R6 — Vibrant colors on top, always.** "Help ensure legibility by using vibrant colors on top of materials... **Regardless of the material you choose, use vibrant colors on top of it.**" Apple's own failure caption: ❌ "Poor contrast between the material and **systemGray3** label". → `labelColor` / `secondaryLabelColor`, never `systemGray*`. Avoid `quaternaryLabel` on thin materials.

**R7 — Size governs behavior.** Small elements (navbars, tabbars) flip light↔dark with the backdrop. "**Bigger elements, like menus or sidebars also adapt based on context, but they don't flip from light to dark. Their surface area is too big and transitions like these would be distracting.**" → **Klip is a big element: adapt, do not flip.**

**R8 — Bigger ⇒ thicker.** "its material characteristics change to simulate a thicker, more substantial material. It casts **deeper, richer shadows**, has **more pronounced lensing**, and a softer scattering of light."

**R9 — Concentricity.** `inner_radius = parent_radius − padding`, from a shared center ([WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/)). Diagnostic: "If something feels off, the answer is simple. Its shape probably needs to be concentric." macOS-specific: Mini/Small/Medium controls use rounded rects; Large/X-Large use capsules.

**R10 — Separation is mandatory.** "Elements using Liquid Glass require clear separation from content to maintain legibility... Without that separation, contrast can suffer." And at rest: "avoid intersections between content and Liquid Glass."

**R11 — Tint sparingly.** "Tinting should only be used to bring emphasis to primary elements and actions... When every element is tinted, nothing stands out. If you want to imbue color into your app, do it in the content layer instead."

**R12 — Legacy material blocks glass.** ([WWDC25 310](https://developer.apple.com/videos/play/wwdc2025/310/)) "If you're using an `NSVisualEffectView` to display that material inside of your sidebar, it will **prevent the glass material from showing through**. You should remove these visual effect views." Same idea as R3, enforced by the renderer. (Only bites on 26+, but it tells you the mental model.)

**R13 — Scroll edge effect, not dividers.** One per view, never stacked, "**not decorative**... shouldn't be used where there aren't any floating UI elements." Hard-edge style is the one for "pinned table headers" — that's Klip's search field.

---

## 3. The recipe, with numbers

These are reverse-engineered readings of Apple's actual CoreUI recipes ([MaterialView source](https://github.com/OskarGroth/MaterialView/blob/main/Sources/MaterialView/NSMaterialView.swift)).

### 3.1 Filter order — this is not the order you think

```swift
backdrop.filters = [saturate, blur, brightness]   // saturate FIRST
```

**Saturate → blur → brightness.** Saturation is boosted *before* the blur averages pixels together. Blur first and you've already averaged the chroma toward grey; there's less left to boost. Every CSS tutorial writes `blur() saturate()` — Apple's pipeline, reversed.

Defaults: `blurRadius = 30.0`, `saturationFactor = 2.5`, backdrop `scale = 0.25` (quarter-res sampling — this is why a 30pt blur is cheap; the downsample does much of the blurring for free).

### 3.2 The two panel recipes (sRGB grey, alpha)

**panelLight**

| state | background | tint | blend | sat | blur |
|---|---|---|---|---|---|
| active | 0.9647 α0.45 | 0.9333 α0.50 | **darken** | 1.8 | 30 |
| inactive | 0.92 α0.60 | 0.9333 α0.70 | darken | 1.2 | 30 |
| emphasized | 0.95 α0.55 | 0.90 α0.60 | darken | 2.2 | 30 |
| reducedTransparency | 0.8784 **α1.0** | — | — | — | — |
| increasedContrast | 0.8235 **α1.0** | — | — | — | — |

Rim: outer white α0.5, no inner.

**panelDark**

| state | background | tint | blend | sat | blur |
|---|---|---|---|---|---|
| active | 0.2157 α0.45 | 0.08627 α0.50 | **lighten** | 1.6 | 30 |
| inactive | 0.18 α0.60 | 0.08627 α0.70 | lighten | 1.2 | 30 |
| emphasized | 0.24 α0.55 | 0.10 α0.60 | lighten | 2.0 | 30 |
| reducedTransparency | 0.12 **α1.0** | — | — | — | — |
| increasedContrast | 0.09804 **α1.0** | — | — | — | — |

Rim: inner **white α0.2**, outer **black α0.8**.

**The invariant across every material Apple ships: light materials darken, dark materials lighten. No exceptions.** Blend constants are the raw CAFilter strings `"darkenBlendMode"`, `"lightenBlendMode"`.

State resolution order: increasedContrast → reducedTransparency → emphasized+inactive → emphasized → inactive → active. Emphasized = base saturation × 1.2.

### 3.3 WHY APPLE DARKENS AND NEVER WHITENS

This is the part everyone gets wrong. **The two layers do opposite jobs, and together they are a dynamic-range compressor — not a veil.**

Take panelLight:

- `backgroundColor` = near-white grey 0.9647 @ α0.45 → normal alpha composite → **raises the luminance floor** (lifts the darks).
- `tintColor` = grey 0.9333 with **darkenBlendMode** → per-channel `min(backdrop, tint)` → **lowers the ceiling**. It clamps anything brighter than 0.9333 and leaves everything darker completely untouched.

Result: the wallpaper's luminance gets squeezed into a narrow band around ~0.93. panelDark is the exact mirror: bg 0.2157 lowers the ceiling, tint 0.08627 with `lightenBlendMode` = `max(backdrop, tint)` raises the floor — so the panel can never collapse to pure black, which would read as a *hole punched in the screen* rather than a surface.

**Apple confirms the model in its own words.** HIG/visionOS: glass "is an adaptive material that **limits the range of background color information** so a window can continue to provide contrast." WWDC25 219: "The amount of tint and the **dynamic range shift** to always ensure buttons remain legible, while letting as much of the content through as possible." HIG on Regular: it "blurs and **adjusts the luminosity** of background content to maintain legibility."

**Three independent reasons a white wash (what naive glassmorphism does) is wrong:**

1. **Math.** `rgba(255,255,255,0.15)` only raises the floor. It has **no ceiling**. Over a bright wallpaper the panel blows out toward white and dark text loses contrast; over dark content it reads as milk. Only a min/darken blend gives you a ceiling.
2. **Physics.** Real glass **attenuates** transmitted light. A passive absorbing medium can subtract luminance; it can never add it. A white overlay *adds* luminance — physically impossible. This is why whitened panels read as plastic or fog and darkened ones read as glass.
3. **Structure.** Darkening **preserves the dark structure of the backdrop** — shapes and edges still read *through* the panel. Whitening erases them. Legible structure behind the surface is precisely what sells "glass" over "frosted plastic".

And Apple's only published opacity number is, tellingly, **black**: "If the underlying content is bright, consider adding a **dark dimming layer of 35% opacity**" ([HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)). Never a white one. (That 35% is **Clear-variant-only guidance — it does not apply to Klip.**)

**Why the saturation boost exists:** blur (spatial averaging) and luminance compression both desaturate. Pushing saturate to 1.8–2.5× restores the chroma energy so the wallpaper's **hue** still reads through even though its **luminance** has been crushed flat. Kill luminance variance, keep hue — *that trade is what Apple calls vibrancy.* The brightness filter is a tiny +0.02–0.03 offset to counteract the darkening.

### 3.4 The rim — two strokes, not one border

```
rim.frame          = bounds.insetBy(dx: -borderWidth, dy: -borderWidth)  // OUTSIDE the clipped container
rim.borderWidth    = 0.5           // outer contour
inner.frame        = bounds.insetBy(dx: borderWidth, dy: borderWidth)
inner.borderWidth  = 1.0           // specular edge
inner.cornerRadius = r
rim.cornerRadius   = r + borderWidth    // ← concentric: outer = inner + stroke width
cornerCurve        = .continuous   // both
```

**This is the detail every CSS clone misses.** A 0.5pt outer contour stroke (separates panel from desktop) **plus** a separate 1pt inner stroke (the bright specular edge reading as the lit thickness of the glass). Dark panels: white α0.2 inner nested inside black α0.8 outer. `border: 1px solid rgba(255,255,255,0.8)` cannot produce that.

The rim layer must live **outside** the clipping container or `masksToBounds` eats the stroke.

Groth's published card recipe: `cornerRadius = 4.5`, `rimOpacity = 0.25`, plus an `NSView.shadow`. Note **0.25** — the rim is subtle by default. Under increasedContrast: rim opacity forced to 1.0, both widths to 1.0, both colors to α1.0.

### 3.5 The specular highlight is a rim *light*, not a gradient

From the [kube.io optical reconstruction](https://kube.io/blog/liquid-glass-css-svg/) — the best published technical work on this:

- Snell–Descartes, n₁ = 1.0 (air) → n₂ = **1.5** (standard glass).
- Bevel profile: **convex squircle `y = ⁴√(1 − (1−x)⁴)`** is Apple's preferred shape — softer flat→curve transition, smoother refraction gradient, holds up in stretched rectangles. Convex circle `y = √(1−(1−x)²)` gives sharper edges. Concave profiles diverge rays outside the object's own bounds — avoid.
- Displacement map: 127 ray samples along the radius, displacement always orthogonal to the border, encoded `r = 128 + x*127, g = 128 + y*127, b = 128, a = 255` (128 = neutral). Max displacement magnitude = the `feDisplacementMap` `scale`.
- Tuned ranges: specular opacity **0.20–0.50**, specular saturation **4–9**, refraction level **0.70–1.00**, light direction ≈ **−60°**.

Because the light direction is fixed and the normal varies around the bezel, **brightness varies around the perimeter** — bright top-left, dim bottom-right. A uniform 1px white border is the wrong *shape*, not just the wrong value.

**The interior is essentially just blur. Budget the effort at the rim.**

---

## 4. What this means on macOS 14

### Cannot have

- `.glassEffect()` / `NSGlassEffectView` / `NSGlassEffectContainerView` / `NSBackgroundExtensionView` — **macOS 26+ only.**
- Real lensing from AppKit. There is no public refraction primitive.
- Automatic Reduce Transparency / Increase Contrast / Reduce Motion adaptation. "These are available automatically **whenever you use the new material**" — a hand-rolled surface inherits **none** of it.
- `CABackdropLayer`, `CAFilter`, `setValue(true, forKey: "clear")`, `CGSSetWindowTags`, `"shouldAutoFlattenLayerTree"`, `"canHostLayersInWindowServer"` — **all private API.** Klip has a Mac App Store goal. **Treat Groth's implementation as reference, not shippable code.**

### Can have — the honest approximation

1. **One** `NSVisualEffectView` for the panel: `material = .popover` (or `.menu` / `.hudWindow` for a genuinely detached utility overlay), `blendingMode = .behindWindow`, `state = .active`. Semantic materials only. Never `.light` — deprecated since 10.14, and R5 forbids the reasoning behind it anyway. `.behindWindow` is the *only* mode that samples the desktop; `.withinWindow` will look dead on a floating panel. (Commit `29ac712` "real behind-window vibrancy" was right.)
2. **The tint/ceiling layer** — the thing that actually makes it read as glass. A plain `CALayer` over the effect view with `compositingFilter = "darkenBlendMode"` and a solid near-white fill at the recipe alpha. Public CA behavior. Mirror to `"lightenBlendMode"` for dark.
3. **The two-stroke concentric rim** — plain `CALayer` borders, `outerRadius = innerRadius + borderWidth`, `cornerCurve = .continuous`, light/dark asymmetry per §3.4. Fully public, and it is the highest-leverage thing on this list.
4. **A shadow** approximating the adaptive one. You can't sample the backdrop cheaply, so pick a slightly deeper static shadow — R8 says a panel-sized surface earns it — and accept the loss.
5. **Vibrant labels** — `labelColor`, `secondaryLabelColor`. Target **7:1** for the small row text, **4.5:1** absolute floor ([HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)).
6. **Concentric row radii**: `rowRadius = panelRadius − padding`. The `maskImage corners` work in `29ac712` should use this, not an arbitrary number.
7. **A soft scroll-edge gradient** at the list boundary instead of hard dividers.
8. **Manual accessibility** — wire `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` and `...ShouldIncreaseContrast` yourself, and copy Apple's escape hatch exactly: **go fully opaque** (light 0.8784 / 0.8235; dark 0.12 / 0.09804 at α1.0), swap backdrop+tint for a solid fill, force the rim to 1pt α1.0. This is not optional polish; it's the accessibility floor.
9. **Strip everything else.** Custom backgrounds in the SwiftUI root, nested effect views, per-row materials — all out. Commit `29ac712`'s "clear SwiftUI root" was the right instinct; finish the job.

### The fork

- **(a) Accept blur, invest in the bezel.** NSVisualEffectView + darken tint + two-stroke rim + shadow. ~90% of the perceived quality for ~10% of the work. **Take this one.**
- **(b) Metal/CIFilter displacement shader** on a captured backdrop using the convex-squircle profile. Real lensing, large lift, ongoing backdrop-capture cost, forfeits every automatic adaptation, and you still hand-roll all the a11y. Only worth it after (a) is shipped and measured.

Forward path: gate on `if #available(macOS 26, *) { .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16)) }` and let the OS do it properly, with (a) as the fallback.

---

## 5. How to judge it — real glass vs. fake glassmorphism

Hold a build against this list. Every ❌ is a tell.

| # | Test | Real | Fake |
|---|---|---|---|
| 1 | **Does the backdrop's dark structure read through?** | Shapes and edges survive behind the panel | Whited-out fog; structure erased |
| 2 | **Over a bright white wallpaper, does it blow out?** | Ceiling clamps, panel stays a distinct surface | Blooms toward white, text contrast dies |
| 3 | **Is there a min/darken blend anywhere?** | Yes — that's the ceiling | Only `rgba(255,255,255,0.15)` = floor with no ceiling |
| 4 | **Is the rim two strokes?** | 0.5pt contour + 1pt specular, concentric radii | One `1px solid white` border |
| 5 | **Does perimeter brightness vary?** | Bright top-left → dim bottom-right (fixed light ≈ −60°) | Uniform glow all the way around |
| 6 | **Is saturation applied before blur?** | `saturate → blur → brightness` | `blur → saturate` (CSS default; hue already averaged out) |
| 7 | **Any glass inside the glass?** | Rows are fills + vibrancy | Glass rows on a glass panel |
| 8 | **Grep for `systemGray`.** | `labelColor` / `secondaryLabelColor` | Hard-coded greys — Apple's literal ❌ example |
| 9 | **Was the material chosen semantically?** | `.popover` because it's a popover | `.light` because it "looks glossiest" |
| 10 | **Reduce Transparency + Increase Contrast, ×2, light/dark.** | Goes fully opaque, rim hardens to α1.0 | Still translucent and unreadable |
| 11 | **Inner radius = outer − padding?** | Yes, shared center | Same radius inside and out, or an eyeballed number |
| 12 | **Does the panel flip light↔dark as it moves?** | No — it's a big element; it adapts without flipping | Flips (small-element behavior on a big surface) |
| 13 | **Where did the effort go?** | The rim | The middle |

**If you only fix three things:** add the darken tint layer (#3), build the two-stroke concentric rim (#4), and wire the opaque accessibility fallback (#10). Those three carry the look and the floor.

---

*Sources inline. Primaries: [WWDC25 219 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/) · [WWDC25 356 Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/) · [WWDC25 310 Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/) · [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) · [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color) · [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) · [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) · [Apple Newsroom, June 2025](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/). Reverse-engineering: [Groth on NSVisualEffectView](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview) + [MaterialView source](https://github.com/OskarGroth/MaterialView/blob/main/Sources/MaterialView/NSMaterialView.swift) (private API — reference only). Optics: [kube.io](https://kube.io/blog/liquid-glass-css-svg/) · [Comeau on backdrop-filter](https://www.joshwcomeau.com/css/backdrop-filter/) · [CSS-Tricks](https://css-tricks.com/getting-clarity-on-apples-liquid-glass/). Trajectory: [MacRumors on Golden Gate](https://www.macrumors.com/2026/06/09/macos-golden-gate-liquid-glass/).*