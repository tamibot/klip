<div align="center">

<img src="docs/klip-mark.svg" width="80">

# Klip

**The clipboard manager for vibe coders — native to Mac.**

Clipboard history · region capture & annotation · OCR to clipboard · scrolling capture · screen recording → GIF · voice & meeting notes, transcribed on-device · copy-as-code-block · batch to PDF/ZIP

Free & open source (Apache 2.0) · No telemetry · Native Swift, no Electron · 100% on-device

[tamibot.github.io/klip](https://tamibot.github.io/klip/)

</div>

---

## 🤔 The loop

Coding with AI is one long copy-paste loop between your editor and Claude, ChatGPT or Cursor. You paste a snippet in, paste the answer back, screenshot the broken UI, re-paste the same stack trace into a second model, and dictate the prompt because the context is already in your head. macOS gives you one clipboard slot and a screenshot that lands on the Desktop.

Klip's answers to that are opinionated on purpose:

- **Local-first, because your clipboard holds your keys.** Everything lives in `~/Library/Application Support/Klip/`. Tokens are encrypted at rest with the key in the Keychain.
- **Everything on-device, because your audio and your screen should not leave the machine.** Transcription runs on Whisper via Core ML. There is no account, no server and nothing to upload to.
- **`⌥⇧` shortcuts, because `⌘⇧`+letter is already taken by your editor.** Option+Shift plus a letter is comfortable to hold, sits on the left of the keyboard, and is rarely claimed — so the global hotkey actually fires.
- **Native Swift, because a clipboard manager that lags is worthless.** AppKit and SwiftUI, real macOS behind-window vibrancy on every floating surface — genuine glass, not a translucent-looking fill.

> **macOS only for now.** macOS 14 (Sonoma) or later, Apple Silicon or Intel. A Windows version is the next big thing on the roadmap.

---

## 🔁 One pass through the loop

**1. You copy. Klip remembers.**
Nothing to press. Every text and image copy lands in the history, grouped by day — *Today* / *Yesterday* / the weekday, each row carrying just its clock time.

**2. You need something from twenty copies ago.**
`⌥⇧E`. Type a few characters, matches highlight as you type. `↑`/`↓`, `Enter` pastes into whatever app you were in. Or narrow with a type chip first: text, links, images, video, voice, credentials, favorites. A chip only appears once you own items of that type.

**3. The UI is broken and describing it is hopeless.**
`⌥⇧D`, drag over the region. The overlay behaves like `⌘⇧4`: no screen dimming, a light gray veil on the selection with a two-device-pixel border and a live dimension badge at the correct Retina scale. Let go and Klip Snap opens — arrow at the bug, rectangle around the misaligned element, a numbered badge on each thing the model should look at, blur over the customer's email. Copy, paste into the chat.

**4. The error is in a screenshot, not selectable text.**
`⌥⇧F`. Snip the region, the text is OCR'd straight onto your clipboard. No editor, no window, nothing to close.

**5. The context is a whole page, not one screen.**
`⌥⇧S`, select the content area. Klip winds the page back to its top, then scrolls and stitches its own way down to the end — one long image. The rewind matters because you scrolled to *find* the thing; without it the capture would start mid-page and stop after one frame.

**6. Explaining the prompt out loud is faster than typing it.**
`⌥⇧R`, talk, `⌥⇧R` again. Transcription runs in the background — start another recording immediately. The text lands in history, the audio stays with it. Add your stack's jargon to Context words (GitHub, React, Supabase, webhook) and the proper nouns come out spelled right.

**7. You bundle the context.**
Hit the ☑ icon in the header, tick the error, the screenshot and the config snippet, and combine them into a PDF (one page per item), a ZIP, or a collection for this task.

**8. You paste it in the shape the model wants.**
`⌘↩` wraps a snippet in triple backticks with a detected language tag. "Copy as Markdown" for one item, or export the whole history. Copying an AI answer out of a dark-themed chat gives you clean text with the bold and the emojis but none of the background, colours or fonts. Then "Copy for WhatsApp" or "Copy for email" when the answer has to go to a human.

Loop closed. Everything you touched is still in the history tomorrow.

---

## 📦 Install

- macOS 14 (Sonoma)+ — tested on macOS 26, Apple Silicon.
- Xcode Command Line Tools only, no full Xcode:

```bash
xcode-select --install
```

**There is no download link, and that is on purpose.** A prebuilt `.app` handed out on the internet needs Apple Developer ID notarization; without it Gatekeeper quarantines the download and macOS calls Klip damaged or from an unidentified developer. Building it on your own Mac sidesteps that: `install.sh` signs with a certificate it makes locally, and the app simply opens.

### Quick install

```bash
git clone https://github.com/tamibot/klip.git klip
cd klip
./install.sh
```

That builds Klip, signs it, copies it to `/Applications` and launches it; Klip registers launch-at-login itself on first run. The icon appears in the menu bar; `⌥⇧E` opens the history.

**The first build takes about two minutes and is quiet for most of them.** Swift Package Manager fetches WhisperKit and everything it drags in — eight packages, around 90 MB of source (`WhisperKit`, `swift-transformers`, `swift-jinja`, `swift-crypto`, `swift-asn1`, `swift-collections`, `swift-argument-parser`, `yyjson`) — before a single file compiles, and then compiles in silence. Later builds reuse `.build/` and take seconds. That download is source code, not the speech model: the model arrives the first time you record a voice note.

Klip starts in your Mac's language if it speaks it (English, Spanish, French, German, Italian, Portuguese, Chinese, Japanese), and in English otherwise. `KLIP_DEFAULT_LANG=fr ./install.sh` forces one; so does Preferences › Language, at any point.

> **On the signing certificate.** On first run `install.sh` creates a local signing certificate ("Klip Code Signing") in your Keychain so the signature is stable. That is what makes macOS remember the microphone, screen-recording and accessibility permissions across updates instead of re-prompting on every reinstall. Local and reversible: delete it from Keychain Access.

### Permissions

Klip asks for three. The first-run window offers all three up front; skip them there and the feature that needs one asks when you first use it. Nothing is captured until you press a shortcut.

| Permission | What needs it | If you say no |
|---|---|---|
| **Screen Recording** | `⌥⇧D` annotate · `⌥⇧F` OCR · `⌥⇧S` scrolling capture · `⌥⇧V` screen recording · the system-audio half of `⌥⇧M` meetings | Those five stop with a pointer to System Settings. Clipboard history and voice notes carry on. |
| **Accessibility** | Auto-paste (`Enter` pasting into the app you came from) and the *automatic* scrolling in `⌥⇧S` | The clip is still copied and focus still returns — you press `⌘V`. Scrolling capture falls back to stitching while *you* scroll, so it still hands you an image. |
| **Microphone** | `⌥⇧R` voice notes and `⌥⇧M` meetings | Neither can start. Nothing else changes. |

Screen Recording is the one macOS only honours after Klip is reopened. Accessibility is never requested behind your back — it comes from the Klip menu → "Enable auto-paste…" or from Preferences › General. macOS may also ask you to approve the login item in Settings › General › Login Items.

### Build without installing

```bash
./build.sh
open Klip.app
```

### Uninstall

```bash
./uninstall.sh              # asks before each step
./uninstall.sh --dry-run    # prints the plan, changes nothing
```

It quits Klip, removes `/Applications/Klip.app` — which takes the launch-at-login registration with it — and deletes the "Klip Code Signing" certificate from your login keychain. Then it asks *separately* about your data: `~/Library/Application Support/Klip`, the `io.github.tamibot.klip` preferences and the credential encryption key in the Keychain, telling you how many images, voice notes and recordings that is before you answer. The default is no. `--keep-data` leaves all of it alone; `--yes` removes everything, data included, without asking.

> **Saving credentials for later takes more than copying the folder.** Klip encrypts credentials at
> rest, and the key lives in the Keychain rather than in `~/Library/Application Support/Klip`. Copy
> the folder and you copy the ciphertext without the key: those items come back permanently
> unreadable. Klip keeps the sealed text rather than discarding it, so nothing gets worse — but
> nothing gets it back either. Reveal and copy anything you still need before you remove the key.

Two things no script may touch, both printed again when it finishes:

- **The permissions.** Remove Klip by hand in System Settings › Privacy & Security under Microphone, Screen Recording ("Screen & System Audio Recording" on macOS 15+) and Accessibility — and in General › Login Items & Extensions if it is still listed.
- **The speech models** in `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`. That is the shared WhisperKit cache and another app may be using it, so deleting it is your call.

### Development

```bash
swift build
swift run Klip
./test.sh
```

---

## ⌨️ Shortcuts

Eight global hotkeys, all `⌥⇧` (Option+Shift) + a letter. All rebindable in Preferences › Shortcuts.

| Shortcut | Action |
|---|---|
| `⌥⇧E` | Open the history panel (**E**dit history) |
| `⌥⇧R` | **R**ecord / stop a voice note |
| `⌥⇧D` | Capture a region and annotate it (**D**raw — Klip Snap) |
| `⌥⇧F` | **F**ast text capture: snip a region → OCR straight to the clipboard, no editor |
| `⌥⇧O` | **O**pen the "upload audio/video to transcribe" window |
| `⌥⇧M` | Record a **M**eeting (mic + system audio) — press again to stop |
| `⌥⇧V` | Record the screen to **V**ideo/GIF, region or full screen, with system audio — again to stop |
| `⌥⇧S` | **S**crolling capture: select an area → Klip scrolls the whole page itself → one long image |

In the panel:

| Key | Action |
|---|---|
| `↑` / `↓` + `Enter` | Navigate and pick |
| `⌘↩` | Copy the selected item as a code block |
| `Esc` | Close |

`⌘⇧⌃4` — macOS's own screenshot-to-clipboard — lands in Klip too.

---

## 🧩 What's inside

### Clipboard

Automatic text and image history · instant search with match highlighting and full keyboard navigation · type filters (text · links · images · video · voice · credentials · favorites) · auto-paste into the active app · favorite ⭐ · delete 🗑 with clear-all confirming first · grouped by day, dates rendered in the UI language you picked, not the system one.

### Capture

- **Region overlay** (`⌥⇧D`, reused by the `⌥⇧V` and `⌥⇧S` pickers) — rebuilt to feel like `⌘⇧4`. No screen dimming: a light gray veil marks the selection, two-device-pixel border, live dimension badge at the correct Retina scale, Apple-style crosshair, hint text that fades on its own, no popup animation. Engine is ScreenCaptureKit, not the deprecated capture API. A preference sends region captures either to the annotation editor or straight to the clipboard.
- **Klip Snap, the annotation editor** — select & move any annotation · pencil · line · arrow · rectangle · ellipse · highlighter · text (editable, movable, resizable) · blur/pixelate · spotlight · numbered counter badges · colour · stroke width · undo/redo · pinch zoom with a live percentage readout. The editor shows the capture and nothing else, no gray dead space around it.
- **OCR** (`⌥⇧F`) — on-device Vision. Snip, and the text is on your clipboard and in history. Also available as a row action on any image.
- **Scrolling capture** (`⌥⇧S`) — select the content area; Klip rewinds to the top, then scrolls and stitches down on its own. Bounded on purpose: **20 steps up, 50 down**, and hard caps of 16 000 px or 120 frames auto-finish with what exists, so an endless feed can't run away and it never fails to save. Stitching matches around the known expected offset — that is what killed the seam artifacts a full-range search produced on repetitive content. Cancel from the pill, with `Esc`, or `⌥⇧S` again to finish now. Needs Accessibility, but is *not* gated up front: that permission is bound to the code signature and can read as denied while System Settings shows it enabled. Klip tries, and if the content provably did not move it falls back to stitching while *you* scroll. Result: an image, not an error.
- **Screen recording** (`⌥⇧V` for a region, menu for full screen) — H.264 video + AAC system audio. Klip's own interface sounds are excluded from the track and its windows never appear in the footage. A floating red frame and stop pill mark the region, the menu-bar icon turns red. Crash-safe: the movie is written in two-second fragments, so a crash still leaves a playable file. The recording lands in history as a card with a poster-frame thumbnail and a duration badge, with row actions to play, reveal, save to Downloads, or **Convert to GIF** (10 fps, ≤1000 px, loops forever, first 30 seconds).

> All capture flows confirm with a toast and deliberately do **not** open the history panel — the panel used to land on top of the very thing you had just captured.

### Voice & meetings

- **Record** (`⌥⇧R`) or **upload files** (`⌥⇧O`): audio (m4a, m4b, mp3, wav, WhatsApp `.opus`, ogg, flac…) and video (mp4, mov, mkv, webm…), whose audio track Klip extracts first.
- **Transcription runs on-device with Whisper (WhisperKit on Core ML). No key, nothing uploaded** — the model downloads once on first use (Tiny ~75 MB · Base ~145 MB · Small ~480 MB · Large v3 Turbo ~1.5 GB), then works offline.
- It runs in the background, so you can start another recording immediately. The **original audio is kept** with duration and a progress bar: play it, reveal it in Finder, retry a failed transcription. (Videos are not stored — only their text.)
- **Per-upload language override**, dictation language with auto-detect, and **context words** — list brands or jargon (GitHub, React, Supabase, webhook) so proper nouns come out spelled right.
- **Meeting notes** (`⌥⇧M`) on any call — Zoom, Meet, Teams, FaceTime. Records your microphone **and** the system audio. No bot joins, nobody sees a recorder. Stop with `⌥⇧M` again, or it stops itself after 15 continuous minutes of silence on both sources. Each track is transcribed separately and interleaved chronologically into a "Me:" / "Them:" transcript. Lands in history as `Meeting — Jul 9, 2:03 PM` (renamable), audio kept and playable, retry on failure.

### Built for pasting into AI

- **Copy as code block** — triple backticks with a detected language tag (`⌘↩` on the selection).
- **Copy for WhatsApp / for email** — WhatsApp markup (`*bold*`, `_italic_`, bullets) or rich email text that keeps bold/italic and paragraph spacing.
- **Always paste clean** (on by default) — a copy from a rich source, like an AI chat on a dark theme, is stored as clean text keeping bold/italic and emojis but dropping the background, colours and fonts.
- **Copy as Markdown** for one item, or export the whole history to Markdown.
- **Save text as a file** (`.txt` / `.md`) to drag into a tool that will not let you paste.
- **Batch multi-select** (the ☑ icon in the header): mark several clips, then combine them into a PDF (one page per screenshot/text, US Letter), export a ZIP (PNGs, `.txt`, audio), or assign them to a collection. Selected rows are marked by the checkmark alone — no blue fill — and the PDF / ZIP / Collection buttons explain themselves on hover.

### Organization & secrets

- **Collections** group the clips of one task, filterable by a chip.
- **Name any item** and find it by that name — especially useful for credentials.
- **Type-aware actions**: open links, colour swatch for hex values (`#1E90FF`).
- **Mini credential manager** — tokens and secrets are detected on copy and encrypted at rest (AES-256-GCM, key in the macOS Keychain, so `items.json` and backups never hold the secret in the clear). Shown masked with a reveal/copy eye, with their own filter, never auto-pasted, and exported to PDF/ZIP/Markdown as a placeholder rather than in the clear.

### Privacy

- Everything local in `~/Library/Application Support/Klip/` (`items.json` + `images/` + `audio/` + `videos/`), files `0600`, folders `0700`. No telemetry, no account, no network service.
- Klip ignores content marked concealed by password managers, and you can exclude specific apps by bundle ID.
- **Export / import the whole history** (images and audio included) as a `.zip`. The import is transactional: on any failure the existing history is restored.
- **Interface in 8 languages**: English, Spanish, French, German, Italian, Portuguese, Chinese (Simplified), Japanese.
- **Stable signing** — macOS asks for microphone, screen-recording and accessibility permissions once and remembers them across updates.
- **Launch at login**, optional. Interface sounds, optional. Reduce Motion honoured.

---

## ⚙️ Preferences

`⌘,` from the Klip menu.

| Section | What is in it |
|---|---|
| **Language** | Interface language |
| **General** | Launch at login · always-paste-clean · auto-paste · sounds · where region captures go (editor or clipboard) · maximum history items |
| **Shortcuts** | Rebind all eight. Defaults `⌥⇧E / R / D / F / O / M / V / S` |
| **Voice transcription** | On-device model, audio language, context words |
| **Privacy** | Ignore content apps mark as concealed |
| **Excluded apps** | Apps Klip never captures from |

---

## 🗺️ Roadmap

- **Windows version** (the big one)
- **Share links to your own bucket** — upload a clip to storage you own and copy a URL. Removed for now, coming back.
- **Favorites sync** and optional sync between Macs

---

## 💡 Ideas & contributing

Ideas and feature proposals are genuinely wanted — open one at [github.com/tamibot/klip/issues](https://github.com/tamibot/klip/issues). A rough paragraph describing the loop you're stuck in is more useful than a polished spec: most of what Klip does started as somebody's annoyance.

Good places to start:

- **A new type-aware quick action.** Row actions live in `HistoryView.swift`'s `moreMenu`; adding one for a detected type (emails, numbers, JSON) is a self-contained change.
- **A "copy for X" formatter.** `Markdownify.swift` already turns a clip into WhatsApp or email shapes; another target is one function plus a menu entry.
- **A language pass.** `L10n.swift` holds eight tables. They must stay key-complete with each other and duplicate-free — a duplicate key in a dict literal traps at *launch*, not at compile time.

It builds with just the Command Line Tools (`swift build`), so there is nothing to set up. Code and comments are in English. Run the tests with `./test.sh`; every push and pull request runs `./build.sh` and `./test.sh` on macOS 14 — results in the repo's [Actions tab](https://github.com/tamibot/klip/actions).

> **Anyone touching panel or window material should read `DESIGN.md` first** — the glass breaks in ways that fail silently.

---

## 🙏 Credits

Created and maintained by Martin Velasco O. — [@tamibot](https://github.com/tamibot).

Collaborators: Sebastian Bimbi — [@sebasbimbi](https://github.com/sebasbimbi) · Miguel Ibarra — [@integralmarketingmx](https://github.com/integralmarketingmx).

Interface sounds rendered from [raphaelsalaja/audio](https://github.com/raphaelsalaja/audio) (MIT © 2026 Raphael Salaja).

---

## 📄 License

Apache 2.0 © 2026 Martin Velasco O.
