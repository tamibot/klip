# Capture suite: recording · scrolling capture · cloud share

Research-backed plan (CleanShot X site + changelog, r/macapps real-usage threads, and the cloud
models of Dropshare/Shottr/Xnapper/Zight/ShareX). What users actually use daily, ranked:
annotation quality (1), scrolling capture (2), recording/GIF (3), pin-to-float (sleeper hit),
OCR (often unbundled), cloud links (polarizing — loved for work, the most-skipped feature
otherwise). CleanShot's most-repeated complaint is licensing, not features — Klip being free and
open source is a moat worth stating loudly.

## 1. Screen recording — SHIPPED (v1)

- `⌥⇧V` (or menu) → region overlay (same frozen-frame picker as `⌥⇧D`) → recording starts on
  release. `⌥⇧V` again / menu stops. Menu-bar icon turns red while live.
- Engine: SCStream video → AVAssetWriter H.264 QuickTime, `movieFragmentInterval` 2 s (a crash
  leaves a playable file), display-sleep assertion held, Klip's own windows excluded from the
  stream, even-rounded pixel dimensions (H.264 4:2:0), session started at the first sample's PTS.
- Output: `.mov` straight to ~/Downloads (the direct-save pattern) + toast with one-tap
  **Convert to GIF** (streamed transcode: 10 fps, ≤1000 px, loop forever — never holds frames).
- v2: SYSTEM AUDIO muxed in (SCStream .audio → AAC track, Klip's own cues excluded); recordings
  land in HISTORY as .video items (poster-frame card, duration badge, play/reveal/save/GIF/share
  row actions, poster in the Recents menu); a floating red frame + stop pill marks the recorded
  region live (RecordingIndicator — Klip windows, so never in the footage). Mic capture still
  deliberately deferred to MeetingRecorder's path.
- Deliberately cut from v1: webcam bubble, pause/resume, countdown, click/keystroke overlays,
  trim editor, FPS/quality prefs. Trim first when asked — it was CleanShot's first editor feature.

## 2. Cloud share — SHIPPED (v1)

Recommendation from the survey: **S3-compatible signed PUT, bring-your-own-bucket** — the exact
shape Shottr 1.9 shipped. No hosted Klip service: user-owned storage is the only cloud that fits
local-first/no-telemetry, and hosted clouds are the most-resented screenshot-app feature.

- Preferences → Sharing: 6 fields (Endpoint · Region, default `auto` · Bucket · Access Key ·
  Secret Key · Public Base URL) + provider preset (R2/S3/B2/MinIO) + **Test connection** (tiny PUT).
- One credential set covers AWS S3, Cloudflare R2 (free 10 GB), Backblaze B2, MinIO (self-hosted =
  maximally local-first), DigitalOcean, Hetzner…
- SigV4 in pure CryptoKit (SHA-256 + HMAC chain over a canonical request) ≈ 100–120 lines, zero
  dependencies. Path-style URLs (R2/MinIO reject virtual-host). Always sign the real payload hash
  (`UNSIGNED-PAYLOAD` breaks on some clones). Surface the server error body on failure (clock skew
  >15 min 403s opaquely).
- UX: **"Copy link"** action on any history item — PUT `klip/UUID.ext`, clipboard gets
  `PublicBaseURL/klip/UUID.ext`, toast. Strictly opt-in per item; never auto-upload.
- Secret via SecretStore (0600 file) for now; Keychain when Developer ID signing lands.

## 3. Scrolling capture — SHIPPED (v2: fully automatic)

Rank-2 daily feature and the #1 documented reason people switch to CleanShot. v1 (manual scroll +
seam-on-mismatch) failed user testing on both counts; v2 is what shipped:

- `⌥⇧S` → drag the CONTENT region → Klip REWINDS THE PAGE TO ITS TOP, then scrolls down itself:
  synthetic pixel-unit wheel events at the region center (cursor warped once), step = 60% of
  region height, ~450 ms settle per step. Rewind matters more than it sounds: you scroll to FIND
  what you want to capture, so without it the capture started mid-page and, at the bottom, ended
  instantly with one frame and a success tick.
- Bounded: 20 steps up, 50 down. On an endless feed that means "start ~20 screens up, take 50
  screens", instead of winding forever.
- Accessibility is NOT gated on up front. AXIsProcessTrusted() is bound to the code signature, so a
  rebuilt app reads false while System Settings still shows it enabled — a state the user cannot
  see. Klip attempts the scroll and judges by whether content MOVED; if it provably did not and we
  are untrusted, it falls back to stitching while the USER scrolls (the stitcher does not care who
  moved the content). `tccutil reset Accessibility <bundle>` is the real fix for a stale entry.
- KNOWN-DELTA stitching: search only expected ± 120 px (kills the false matches that caused v1's
  seams); one full-range retry; still no match OR identical frame → END OF PAGE → auto-finish.
  NO seam lines ever — degraded overlap beats a visible artifact.
- Caps (16 000 px / 120 frames) auto-finish with what exists — never a failed save.
- Cancel: pill button, global Esc (session-scoped Carbon hotkey — a local monitor never fires
  because Klip isn't the active app), or ⌥⇧S again = finish-now.
- Result → history + clipboard like any capture (OCR-searchable), confirmed by a TOAST. Capture
  flows (⌥⇧D/⌥⇧F/⌥⇧S) deliberately no longer reveal the history panel: they are their own errand,
  and the panel landed on top of the thing just captured.
- Still cut: horizontal, manual repositioning, multi-page print.

## Also cheap and loved (candidates)

- **Pin to float**: an always-on-top NSPanel showing a history image — repeatedly called an
  "absolute favorite" in the threads and nearly free on AppKit.
- Repeat-last-region capture with the region outline shown beforehand.
