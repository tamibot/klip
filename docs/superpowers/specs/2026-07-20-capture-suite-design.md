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
- Video-only on purpose: audio is the single most-patched area of CleanShot's changelog
  (engine rewrite 4.6, distortion 3.6.2, bitrate 4.6.1, interface-mic 4.8.8). When audio lands it
  reuses MeetingRecorder's already-debugged SCStream audio path — not a new one.
- Deliberately cut from v1: webcam bubble, pause/resume, countdown, click/keystroke overlays,
  trim editor, FPS/quality prefs. Trim first when asked — it was CleanShot's first editor feature.

## 2. Cloud share — NEXT (small)

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

## 3. Scrolling capture — AFTER (large, tuning-heavy)

Rank-2 daily feature and the #1 documented reason people switch to CleanShot — but the stitching
quality bar is empirical (CleanShot rewrote its algorithm in 3.9.4 and again in 4.8). Do it when
it can get uninterrupted tuning time.

- `⌥⇧S` → drag the CONTENT region (excluding sticky headers/scrollbars is the only real defense
  against duplicated-header artifacts — caption says so) → floating Start → user scrolls the app
  manually (manual-first: CleanShot shipped manual 4 years before auto-scroll) → live-stitch
  preview strip → Done → one long PNG to Downloads + history.
- Engine: repeated `SCScreenshotManager.captureImage` of the rect, global scroll-wheel monitor
  debounced ~200 ms (momentum frames stitch garbage), dedupe identical frames, vertical offset by
  row-sum correlation (Accelerate, ~100 lines), composite into one canvas.
- Cap canvas height and SAVE WHAT YOU HAVE on hitting it — CleanShot's concrete user complaint is
  a too-long capture that cannot be saved at all. On a failed offset match, append with a visible
  seam rather than aborting: degraded output beats no output.
- Cut from v1: auto-scroll, horizontal, manual stitch repositioning, multi-page print.

## Also cheap and loved (candidates)

- **Pin to float**: an always-on-top NSPanel showing a history image — repeatedly called an
  "absolute favorite" in the threads and nearly free on AppKit.
- Repeat-last-region capture with the region outline shown beforehand.
