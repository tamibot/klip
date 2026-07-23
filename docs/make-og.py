#!/usr/bin/env python3
"""Generate docs/og.png — the 1200x630 social preview card for the Klip landing page.

    python3 docs/make-og.py          # writes docs/og.png (and docs/og.svg alongside it)

Requires cairosvg (`pip3 install cairosvg`). Run it from anywhere; paths are resolved
relative to this file.

WHY a generator and not a hand-made PNG: the card carries the app icon, the positioning
line and the feature set. All three drift. Regenerating is a one-liner; re-drawing in a
design tool is not, so the last version rotted for a month advertising a paperclip icon
and a feature set that had lost half of what Klip does.

The icon is not redrawn here — the rects are lifted verbatim from Resources/AppIcon.svg,
so the card can never disagree with the shipped icon.

Colours and type scale mirror docs/index.html's tokens; keep them in step if those move.

FONT: cairo's "toy" text API takes ONE family name and does no fallback, and it resolves
families through fontconfig, which does not know the marketing name "SF Pro". "System
Font" is fontconfig's name for /System/Library/Fonts/SFNS.ttf — i.e. real SF Pro. That
makes this script macOS-only; on another OS set FONT to something present there.
"""

import re
from pathlib import Path

import cairocffi as cairo
import cairosvg

ROOT = Path(__file__).resolve().parent.parent
OUT_PNG = ROOT / "docs" / "og.png"

W, H = 1200, 630          # declared in the og:image:width/height meta tags — do not change
CX = W / 2

FONT = "System Font"      # see module docstring

# docs/index.html design tokens
INK = "#1c1c1e"
INK2 = "#3a3a3e"
MUTED = "#6a6a72"
FAINT = "#9a9aa1"
ACCENT = "#5b6bf0"
OK = "#2b9d4b"            # green is reserved for the privacy claim, on the site and here

FEATURES = [
    ["Searchable history", "Capture & annotate", "OCR text", "Voice notes"],
    ["Meeting notes", "Screen recording", "Scrolling capture", "Key vault"],
]

# ---------------------------------------------------------------- text metrics
# Same toy API cairosvg renders with, so these advances are what actually lands.
_ctx = cairo.Context(cairo.SVGSurface(None, 10, 10))


def adv(text, size, bold=False, tracking=0.0):
    """Advance width of `text`. `tracking` is cairosvg's letter-spacing: it adds the value
    after every glyph, including the last one."""
    _ctx.select_font_face(
        FONT, cairo.FONT_SLANT_NORMAL,
        cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
    _ctx.set_font_size(size)
    return _ctx.text_extents(text)[4] + len(text) * tracking


def label(text, x, y, size, fill, bold=False, tracking=0.0):
    ls = f" letter-spacing='{tracking}'" if tracking else ""
    weight = "bold" if bold else "normal"
    return (f"<text x='{x:.1f}' y='{y:.1f}' font-family='{FONT}' font-size='{size}' "
            f"font-weight='{weight}'{ls} fill='{fill}'>{text}</text>")


def row(parts, y, size, cx=CX):
    """Lay out ['text', fill, bold] runs on one baseline, centred on `cx`."""
    total = sum(adv(t, size, b) for t, _, b in parts)
    x = cx - total / 2
    out = []
    for text, fill, bold in parts:
        out.append(label(text.replace("&", "&amp;"), x, y, size, fill, bold))
        x += adv(text, size, bold)
    return "".join(out)


# ---------------------------------------------------------------- app icon
def icon(x, y, box):
    """The real mark from Resources/AppIcon.svg, scaled so its 824-unit tile is `box` wide."""
    src = (ROOT / "Resources" / "AppIcon.svg").read_text()
    rects = "".join(re.findall(r"<rect\b[^>]*/>", src))
    s = box / 824
    return (f"<g transform='translate({x:.1f},{y:.1f}) scale({s:.5f}) "
            f"translate(-100,-100)'>{rects}</g>")


# ---------------------------------------------------------------- pieces
def chips(labels, y, size=26, h=56):
    """A row of glass pills, centred. Each pill: accent dot + label."""
    pad_l, pad_r, dot_gap, gap = 19, 21, 12, 12
    r = 4.5
    widths = [pad_l + r * 2 + dot_gap + adv(t, size) + pad_r for t in labels]
    x = CX - (sum(widths) + gap * (len(labels) - 1)) / 2
    out = []
    for text, w in zip(labels, widths):
        out.append(
            f"<rect x='{x:.1f}' y='{y}' width='{w:.1f}' height='{h}' rx='{h/2}' "
            f"fill='rgba(255,255,255,.62)' stroke='rgba(0,0,0,.09)' stroke-width='1'/>"
            f"<circle cx='{x + pad_l + r:.1f}' cy='{y + h/2}' r='{r}' fill='{ACCENT}'/>")
        out.append(label(text.replace("&", "&amp;"), x + pad_l + r * 2 + dot_gap,
                         y + h / 2 + size * 0.35, size, INK2))
        x += w + gap
    return "".join(out)


def tick(x, y, size):
    """The landing page's .trust checkmark (24-unit viewBox), scaled to `size`."""
    s = size / 24
    return (f"<g transform='translate({x:.1f},{y:.1f}) scale({s:.4f})' fill='none' "
            f"stroke='{OK}' stroke-width='2.6' stroke-linecap='round' "
            f"stroke-linejoin='round'><path d='M4.5 12.5 9.5 17.5 19.5 6.5'/></g>")


def build():
    p = []
    p.append(f"""<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}'
     viewBox='0 0 {W} {H}'>
  <defs>
    <linearGradient id='wash' x1='0' y1='0' x2='0' y2='1'>
      <stop offset='0' stop-color='#f1f1f3'/><stop offset='1' stop-color='#e6e6e9'/>
    </linearGradient>
    <radialGradient id='glow' cx='.5' cy='0' r='.8'>
      <stop offset='0' stop-color='{ACCENT}' stop-opacity='.11'/>
      <stop offset='1' stop-color='{ACCENT}' stop-opacity='0'/>
    </radialGradient>
  </defs>
  <rect width='{W}' height='{H}' fill='url(#wash)'/>
  <rect width='{W}' height='{H}' fill='url(#glow)'/>""")

    # --- wordmark row: icon + "Klip", centred as a group
    icon_box, gap, name_size = 112, 24, 62
    name_w = adv("Klip", name_size, bold=True, tracking=-1.8)
    gx = CX - (icon_box + gap + name_w) / 2
    p.append(icon(gx, 46, icon_box))
    p.append(label("Klip", gx + icon_box + gap, 46 + icon_box / 2 + name_size * 0.35,
                   name_size, INK, bold=True, tracking=-1.8))

    # --- headline. The site's h1 wording, with the accent on "vibe coders".
    p.append(row([("The clipboard manager", INK, True)], 254, 68))
    p.append(row([("for ", INK, True), ("vibe coders.", ACCENT, True)], 330, 68))

    # --- the strongest claim, in the green the site reserves for privacy
    ts = 34
    a, b = "100% on-device — ", "your clips never leave your Mac."
    tick_w = 31
    total = tick_w + 12 + adv(a, ts) + adv(b, ts, bold=True)
    x = CX - total / 2
    p.append(tick(x, 394 - ts * 0.82, tick_w))
    p.append(row([(a, INK2, False), (b, OK, True)],
                 394, ts, cx=x + tick_w + 12 + (total - tick_w - 12) / 2))

    # --- what ships today
    p.append(chips(FEATURES[0], 432))
    p.append(chips(FEATURES[1], 500))

    p.append(row([("Free & open source  ·  Native Swift, no Electron  ·  macOS 14+",
                   FAINT, False)], 592, 22))

    p.append("</svg>")
    return "\n".join(p)


if __name__ == "__main__":
    # ponytail: the SVG is not kept — it is a build intermediate, and this script IS its source.
    # To eyeball how a social client will shrink the card, re-render build() at output_width=300.
    cairosvg.svg2png(bytestring=build().encode(), write_to=str(OUT_PNG),
                     output_width=W, output_height=H)
    print(f"wrote {OUT_PNG}")
