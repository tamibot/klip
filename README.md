<div align="center">

# 📋 Klip

**The clipboard manager for vibe coders — native to Mac.**

Clipboard history · region capture & annotation · scrolling capture · OCR to clipboard · voice, video & meeting transcription · screen recording → GIF · copy-as-code-block · share links to your own bucket

Free & open source (Apache 2.0) · No telemetry · Native Swift, no Electron · Local-first

[tamibot.github.io/klip](https://tamibot.github.io/klip/)

</div>

---

## 🤔 Why

Coding with AI is one long copy-paste loop.

You copy a snippet into Claude. You copy the answer back. You screenshot the broken UI and drag it into ChatGPT. You paste a stack trace, then the same stack trace again into Cursor. You copy an error out of a terminal, an API key out of a dashboard, a hex value out of Figma. You dictate a prompt because typing it out is three paragraphs of context you already have in your head.

macOS gives you one clipboard slot and a screenshot that lands on the Desktop. Klip is built for that loop: everything you copied is still there, everything you capture is already formatted for pasting into a model, and nothing leaves your Mac unless you tell it to.

Its answers are opinionated on purpose:

- **Local-first, because your clipboard holds your keys.** Everything lives in `~/Library/Application Support/Klip/`. Tokens are encrypted at rest. Nothing is uploaded unless you click the button that uploads it.
- **On-device transcription by default, because audio should not leave the machine.** Whisper runs on Core ML. Cloud engines exist, but you opt in and bring your own key.
- **Your own S3 bucket for share links, because the storage should be yours.** There is no hosted Klip service and no middleman, and nothing is ever uploaded automatically.
- **⌥⇧ shortcuts, because ⌘⇧+letter is already taken by your editor.** Option+Shift plus a letter is comfortable to hold, sits on the left of the keyboard, and is rarely claimed by other apps — so the global hotkey actually fires.

> **macOS only for now.** macOS 14 (Sonoma) or later, Apple Silicon or Intel. A Windows version is the next big thing on the roadmap.

---

## ⚡ What you get, at a glance

| Domain | Klip does |
|---|---|
| **Clipboard** | Automatic text + image history, instant search with match highlighting, type filters, favorites, auto-paste, day-grouped list |
| **Region capture** | ScreenCaptureKit overlay that behaves like `⌘⇧4`, then a full annotation editor (arrows, blur, spotlight, counters, text) |
| **OCR** | `⌥⇧F` — snip a region, text lands on the clipboard. On-device Vision, no editor step |
| **Scrolling capture** | `⌥⇧S` — select an area, Klip rewinds to the top and scrolls itself, stitches one long image |
| **Screen recording** | `⌥⇧V` — region or full screen, H.264 + system audio, lands in history, one-click Convert to GIF |
| **Voice → text** | `⌥⇧R` to dictate, `⌥⇧O` to upload audio *or video* files; background transcription, original audio kept |
| **Meeting notes** | `⌥⇧M` — mic **+** system audio, no bot joins the call, "Me:" / "Them:" transcript, never uploaded |
| **AI engines** | On-device Whisper by default (WhisperKit / Core ML). OpenAI or Gemini optional, your own key |
| **Paste into AI** | Copy as code block with detected language, copy for WhatsApp / email, always-paste-clean, Markdown export |
| **Batch** | Multi-select clips → PDF, ZIP, or assign to a collection |
| **Secrets** | Tokens and API keys detected on copy, AES-256-GCM at rest, key in the Keychain, masked, never auto-pasted |
| **Share links** | Upload a clip to your own S3-compatible bucket (R2, S3, B2, MinIO…) and get a URL. Opt-in per click |
| **Privacy** | Everything in `~/Library/Application Support/Klip/`, `0600` files, no telemetry, password-manager content ignored |

---

## 🔁 Usage — one pass through the loop

This is the whole point of the app, so here it is end to end.

**1. You copy. Klip remembers.**
Nothing to press. Every text and image copy goes into the history. The list is grouped by day — headers read "Today" / "Yesterday" / the weekday, each row carries just its clock time.

**2. You need something from twenty copies ago.**
`⌥⇧E`. Type a few characters — search matches are highlighted as you type. `↑`/`↓` to move, `Enter` to paste it into whatever app you were in. Or narrow first with a type chip: text, links, images, voice, credentials, favorites. A chip only shows up once you actually own items of that type.

**3. The UI is broken and describing it is hopeless.**
`⌥⇧D`, drag over the region. The overlay behaves like macOS's own `⌘⇧4` — it does not dim your screen, it lays a light gray veil over the selection with a two-device-pixel border and a live dimension badge at the correct Retina scale. Let go and Klip Snap opens: arrow at the bug, rectangle around the misaligned element, a numbered badge on each thing you want the model to look at, blur over the customer's email address. Copy. Paste into the chat.

**4. The error is in a screenshot, not selectable text.**
`⌥⇧F`. Snip the region — the text is OCR'd straight onto your clipboard and into history. No editor, no window, nothing to close. Paste the error into the AI as text.

**5. The context is a whole page, not one screen.**
`⌥⇧S`, select the content area. Klip winds the page back to its top, then scrolls and stitches its own way down until it hits the end — one long image. The rewind matters because you scrolled to *find* the thing; without it the capture would start mid-page and stop at the bottom after one frame.

**6. Explaining the prompt out loud is faster than typing it.**
`⌥⇧R`, talk, `⌥⇧R` again. The transcription runs in the background — start another recording immediately if you want. The text lands in history, the audio stays with it so you can play it back. Add your stack's jargon to Context words (GitHub, React, Supabase, webhook) and the proper nouns come out spelled right.

**7. You bundle the context.**
Hit the ☑ icon in the header, tick the error, the screenshot and the config snippet, and combine them into a PDF (one page per item), a ZIP, or a collection for this task.

**8. You paste it in the shape the model wants.**
`⌘↩` on a snippet wraps it in triple backticks with a detected language tag. "Copy as Markdown" for one item, or export the whole history to Markdown. Copying an AI answer out of a dark-themed chat gives you clean text with the bold and the emojis but none of the background, colours or fonts. Then "Copy for WhatsApp" or "Copy for email" when the answer has to go to a human instead.

Loop closed. Everything you touched is still in the history tomorrow.

---

## 📦 Requirements & install

- macOS 14 (Sonoma)+ — tested on macOS 26, Apple Silicon.
- Xcode Command Line Tools only, no full Xcode:

```bash
xcode-select --install
```

An OpenAI or Google Gemini API key is optional — only if you want a cloud transcription engine instead of the on-device one. It is stored in a local file, never in the repo.

### Quick install

```bash
git clone https://github.com/tamibot/klip.git klip
cd klip
./install.sh
```

That builds Klip, signs it, copies it to `/Applications`, launches it and registers launch-at-login. The 📋 icon appears in the menu bar; `⌥⇧E` opens the history.

> **On the signing certificate.** On first run `install.sh` creates a local signing certificate ("Klip Code Signing") in your Keychain so the signature is stable. That is what makes macOS remember the microphone, screen-recording and accessibility permissions across updates instead of re-prompting on every reinstall. Local and reversible: delete it from Keychain Access.

macOS may ask you to approve the login item in Settings › General. For auto-paste, grant Accessibility when prompted (Klip menu → "Enable auto-paste…"). The first `⌥⇧D` asks for Screen Recording.

### Build without installing

```bash
./build.sh
open Klip.app
```

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

## 📋 Clipboard

- **Automatic history** of text and images/screenshots.
- **Instant search** with match highlighting and full keyboard navigation.
- **Type filters**: text · links · images · voice · credentials · favorites. A type chip only appears once you actually own items of that type.
- **Auto-paste** into the active app · favorite ⭐ · delete 🗑 (clear-all asks first).
- **Grouped by day**: headers read *Today* / *Yesterday* / the weekday, each row carries just its clock time. Dates render in the UI language you picked, not the system one.

---

## 📸 Capture suite

### Region overlay — `⌥⇧D` (reused by the `⌥⇧V` and `⌥⇧S` pickers)

- Rebuilt to feel like macOS's own `⌘⇧4`. It does not dim the screen: a light gray veil marks the selection, with a two-device-pixel border and a live dimension badge at the correct Retina scale.
- Custom Apple-style crosshair cursor, hint text that fades out on its own, and the overlay presents instantly — no popup animation.
- Engine is ScreenCaptureKit, not the deprecated capture API.

### Annotation editor — Klip Snap

Select & move any annotation · pencil · line · arrow · rectangle · ellipse · highlighter · text (editable, movable, resizable) · blur/pixelate · spotlight · numbered counter badges · colour · stroke width · undo/redo · pinch zoom with a live percentage readout.

What that buys you on a broken screen: arrow at the bug, rectangle around the misaligned element, a numbered badge on each thing you want the model to look at, blur over the customer's email address. The editor shows the capture and nothing else — no gray dead space around it.

### Fast text capture — `⌥⇧F`

Snip a region and the text is OCR'd straight onto your clipboard and into history — no editor, no window, nothing to close.

### Scrolling capture — `⌥⇧S`, fully automatic

- Select the content area. Klip winds the page back to its top, then scrolls and stitches its way down on its own, finishing when it reaches the end.
- **Why the rewind matters**: you scroll to *find* the thing you want to capture. Without it, the capture started mid-page and ended instantly at the bottom with a single frame.
- **Bounded**: 20 steps up, 50 down — an endless feed cannot run away. Further caps (16 000 px or 120 frames) auto-finish with what exists, so it never fails to save.
- **Stitching matches around the known expected offset** — that is what killed the seam artifacts an earlier full-range search produced on repetitive content. No seam line is ever drawn.
- **Cancel** from the pill, with global `Esc`, or `⌥⇧S` again to finish now. A floating frame marks the region while it runs.
- Needs Accessibility (the same permission auto-paste uses). It is *not* gated up front: that permission is bound to the code signature and can read as denied while System Settings shows it enabled. So Klip tries, and if the content provably did not move it falls back to stitching while *you* scroll. Result: an image, not an error.

### Screen recording — `⌥⇧V` for a region, menu for full screen

- Video + system audio (H.264 + AAC). Klip's own interface sounds are excluded from the track, and Klip's own windows never appear in the footage.
- A floating red frame plus a stop pill marks the recorded region while it is live; the menu-bar icon turns red. `Esc` closes the floating windows.
- **Crash-safe**: the movie is written in fragments, so a crash still leaves a playable file.
- The recording lands in history like any other clip — a card with a poster-frame thumbnail and a duration badge, a poster in the Recents menu, and row actions to play, reveal, save to Downloads, Convert to GIF, or copy a share link. GIF export is a streamed transcode (10 fps, ≤1000 px, loops forever) that never holds the frames in memory.

> All capture flows confirm with a toast and deliberately do **not** open the history panel — the panel used to land on top of the very thing you had just captured.

---

## 🎙️ Voice & video → text

- **Record** (`⌥⇧R`) or **upload files** (`⌥⇧O`): audio (m4a, mp3, wav, WhatsApp `.opus`, ogg, flac…) and video (mp4, mov, mkv, webm…) — Klip extracts the video's audio track and transcribes it.
- Transcription runs in the background; start another recording immediately.
- The **original audio is kept**, with duration and a progress bar: play it, reveal it in Finder, retry if a transcription fails. (Videos are not stored — only their text.)
- **Per-upload language override**, and clear per-file errors: DRM-protected video, no audio track, too large for the cloud engine.

---

## 🧑‍💻 Meeting notes — no bot, no cloud

- `⌥⇧M` when you join any call — Zoom, Meet, Teams, FaceTime, any app. Records your microphone **and** the system audio (everyone else). No bot joins; nobody sees a recorder.
- Stop with `⌥⇧M` again, or it stops itself after 15 minutes of silence. Both tracks are mixed locally and transcribed. With the on-device engine each track is transcribed separately and interleaved chronologically as a "Me:" / "Them:" transcript.
- Lands in history as `Meeting — Jul 9, 2:03 PM` (renamable), audio kept and playable, retry on failure. The audio is never uploaded anywhere.

---

## 🧠 AI engines — you pick

| Engine | Models | Key needed | Audio leaves the Mac |
|---|---|---|---|
| **On-device (default)** | Whisper via [WhisperKit](https://github.com/argmaxinc/WhisperKit) on Core ML — Tiny / Base / Small / Large v3 Turbo | No | Never |
| **OpenAI** | `gpt-4o-mini-transcribe`, `whisper-1` | Yes, yours | Yes |
| **Google Gemini** | `gemini-flash-latest`, `-flash-lite-latest`, `-pro-latest`, `2.5-flash`, `2.5-pro` | Yes, yours | Yes |

On-device models are downloaded once on first use, then fully offline.

- **Dictation language** is selectable, with auto-detect.
- **Context words**: list names, brands or jargon (GitHub, React, Supabase, API, webhook) so proper nouns come out spelled right. Works with the on-device engine too.

---

## 🤖 Built for pasting into AI

- **Copy as code block** — wraps in triple backticks with a detected language tag (`⌘↩` on the selection).
- **Copy for WhatsApp / for email** — reformats so it pastes cleanly: WhatsApp markup (`*bold*`, `_italic_`, bullets) or rich email text that keeps bold/italic and paragraph spacing.
- **Always paste clean** (on by default) — a copy from a rich source, like an AI chat on a dark theme, is stored as clean text that keeps bold/italic and emojis but drops the background, colours and fonts.
- **Copy as Markdown** for one item, or export the whole history to Markdown.
- **Save text as a file** (`.txt` / `.md`) to drag into a tool that will not let you paste.
- **Batch multi-select** (the ☑ icon in the header): mark several clips, then combine them into a PDF (one page per screenshot/text), export them as a ZIP, or assign them to a collection. Selected rows are marked by the checkmark alone — no blue fill — and the PDF / ZIP / Collection buttons explain themselves on hover.

---

## 🗂️ Organization

- **Collections** — group the clips of one task and filter by a chip.
- **Name any item** and find it by that name (especially useful for credentials).
- **Type-aware actions** — open links, colour swatch for hex values (`#1E90FF`).
- **Mini credential manager** — tokens and API keys are detected on copy and encrypted at rest (AES-256-GCM, key in the macOS Keychain, so `items.json` and backups never hold the secret in the clear). Shown masked with a reveal/copy eye, with their own filter, and never auto-pasted.

---

## 🔗 Share links — your own cloud, no middleman

"Copy link" on any clip uploads it to **your own** S3-compatible bucket and puts the URL on the clipboard. Cloudflare R2 (10 GB free), AWS S3, Backblaze B2, MinIO (self-hosted), DigitalOcean, Hetzner — one credential set covers them all.

Preferences › Share links takes endpoint, region, bucket, access key, secret key and public base URL, plus a provider preset, a **Test connection** button, and a built-in 5-minute Cloudflare R2 walkthrough. SigV4 signing is written in pure CryptoKit — no AWS SDK, no dependency.

Strictly opt-in per click. Nothing is ever uploaded automatically, and there is no hosted service: the storage is yours.

---

## 🔒 Backup · languages · privacy

- **Export / import the whole history** (images and audio included) as a `.zip`. Never includes API keys.
- **Interface in 8 languages**: English, Spanish, French, German, Italian, Portuguese, Chinese (Simplified), Japanese.
- Everything local in `~/Library/Application Support/Klip/` (`items.json` + `images/` + `audio/`), files `0600`, folders `0700`. No telemetry.
- Klip ignores content marked concealed by password managers, and you can exclude specific apps.
- **Stable signing**: macOS asks for permissions (microphone, screen recording, accessibility) once and remembers them across updates.
- **Launch at login**, optional.

---

## ✨ The look

- Real macOS behind-window vibrancy on every floating surface — the panel, the popover, the auxiliary windows. Genuine glass, not a translucent-looking fill. It is fragile in ways that fail silently, which is why the reasoning lives in `DESIGN.md` and contributors are told to read it first.
- SF Symbols throughout, press-down feedback on buttons (respond on press, as Apple does), smooth symbol transitions, Reduce Motion honoured.
- Toasts instead of window reveals for anything that is its own errand.
- Subtle interface sounds, and they can be turned off.

---

## ⚙️ Configuration

**Preferences** — `⌘,` from the Klip menu.

| Section | What is in it |
|---|---|
| **Shortcuts** | Rebind all eight. Defaults `⌥⇧E / R / D / F / O / M / V / S` |
| **Voice transcription** | Provider (on-device, OpenAI, Gemini), model, language, context words |
| **OpenAI / Google Gemini** | The API key for the provider you chose (only that section shows), in a local `0600` file |
| **Share links** | Your bucket: endpoint, region, bucket, keys, public URL, Test connection, R2 guide |
| **History** | Maximum number of items |
| **Privacy** | Ignore passwords/sensitive content, exclude apps, always-paste-clean toggle |
| **Language** | Interface language |

---

## 🏗️ Architecture

| File | Responsibility |
|---|---|
| `main.swift` / `AppDelegate.swift` | Startup, menu bar, Edit menu, the eight global shortcuts |
| `ClipboardManager.swift` | Clipboard monitoring, history, source, privacy, collections |
| `ClipboardItem.swift` / `Storage.swift` | Model and persistence (JSON + images + audio + PDF/ZIP) |
| `PanelController.swift` / `HistoryView.swift` | HUD panel and the SwiftUI UI, multi-select and export |
| `Glass.swift` | Behind-window vibrancy: real macOS glass for every floating surface. Why: `DESIGN.md` |
| `SnapController.swift` / `ScreenCapturer.swift` | Native capture flow, incl. fast OCR-to-clipboard (`⌥⇧F`) |
| `CaptureOverlayController.swift` | Region-selection overlay (freeze-frame, veil, badge, crosshair) |
| `SnapEditorController.swift` / `AnnotationCanvasView.swift` / `AnnotationModel.swift` | Annotation editor and model |
| `HotKey.swift` / `Settings.swift` | Shortcuts (Carbon) and preferences (UserDefaults) |
| `OCR.swift` | Text extraction with Vision, on-device |
| `CredentialCrypto.swift` / `CredentialDetector.swift` | Credential detection + AES-256-GCM at rest |
| `RichText.swift` | Rich clipboard text → clean Markdown, for always-paste-clean |
| `UploadView.swift` | The upload-audio/video window with live per-file results |
| `Recorder.swift` / `AudioPlayer.swift` | Recording, background transcription, voice-note playback |
| `MediaAudioExtractor.swift` | Extracts a video's audio track (AVAssetReader→Writer, 16 kHz mono AAC) |
| `MeetingRecorder.swift` | Meeting notes: mic + system audio, local mix, Me/Them dual-track transcription |
| `ScreenRecorder.swift` | Screen recording: region/full screen → H.264 + system-audio AAC, + GIF export |
| `ScrollCaptureController.swift` | Scrolling capture: rewind-to-top, synthetic scrolling, known-delta stitching, manual fallback |
| `RecordingIndicator.swift` | The floating red frame and stop pill marking a live recording or scroll capture |
| `ToastHUD.swift` | The transient confirmations capture flows use instead of opening the panel |
| `WelcomeView.swift` / `GuideView.swift` | First-run onboarding and the in-app setup guides |
| `S3Uploader.swift` | Share links: SigV4-signed PUT to the user's own bucket, pure CryptoKit |
| `OpenAIClient.swift` / `GeminiClient.swift` / `LocalTranscriber.swift` | OpenAI, Gemini or on-device WhisperKit |
| `L10n.swift` | Lightweight localization, 8 languages |
| `SecretStore.swift` | API keys in local `0600` files |
| `Paster.swift` / `LoginItem.swift` | Auto-paste and launch-at-login |
| `Markdownify.swift` | Markdown conversion and export |
| `SoundFX.swift` | Interface sounds, rendered from the raphaelsalaja/audio kits (`Resources/Sounds/bake-sounds.mjs`) |

---

## 🗺️ Roadmap

- **Windows version** (the big one)
- More type-aware quick actions (emails, numbers)
- Translate / summarize / clean up text with AI
- Favorites sync and optional sync between Macs
- Developer ID signing + notarization for warning-free distribution

---

## 🤝 Contributing

Contributions welcome — issues and PRs. Klip builds with just the Command Line Tools, so it is easy to start. Code and comments are in English. Run tests with `./test.sh`.

> **Anyone touching panel or window material should read `DESIGN.md` first** — the glass breaks in ways that fail silently.

---

## 🙏 Credits

Created and maintained by Martin Velasco O. — [@tamibot](https://github.com/tamibot). Collaborator: Sebastian Bimbi — [@sebasbimbi](https://github.com/sebasbimbi).

Interface sounds rendered from [raphaelsalaja/audio](https://github.com/raphaelsalaja/audio) (MIT © 2026 Raphael Salaja).

---

## 📄 License

Apache 2.0 © 2026 Martin Velasco O.
