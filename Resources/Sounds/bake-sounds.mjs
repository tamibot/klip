// Renders Klip's interface sounds to WAV from the raphaelsalaja/audio sound kits
// (https://github.com/raphaelsalaja/audio, MIT © 2026 Raphael Salaja).
//
// The kits define each sound as a synthesis patch (oscillators + envelopes), not as audio
// files; this script renders them offline with the library's own renderToBuffer(), so the
// bundled WAVs are byte-for-byte what the library plays on the web.
//
// Regenerate (or switch kits) with:
//   npm install @web-kits/audio node-web-audio-api
//   node Resources/Sounds/bake-sounds.mjs [--kit core] [--out Resources/Sounds]
//
// The kit JSON is fetched from the library's repo unless --kit points to a local .json file.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  AudioBuffer as NodeAudioBuffer,
  AudioContext as NodeAudioContext,
  OfflineAudioContext as NodeOfflineAudioContext,
} from "node-web-audio-api";

// Polyfill the Web Audio globals BEFORE importing @web-kits/audio (same trick as the
// library's own scripts/bake-sounds.ts).
const g = globalThis;
if (!g.OfflineAudioContext) g.OfflineAudioContext = NodeOfflineAudioContext;
if (!g.AudioContext) g.AudioContext = NodeAudioContext;
if (!g.AudioBuffer) g.AudioBuffer = NodeAudioBuffer;
if (!g.BaseAudioContext) g.BaseAudioContext = NodeAudioContext;

const { renderToBuffer } = await import("@web-kits/audio");

// Klip event → kit sound. Only these are baked; everything else in the kit is ignored.
const SOUNDS = [
  "copy", "success", "save", "error", "warning", "delete",
  "toggle-on", "toggle-off", "pop", "loading-start", "loading-end",
];

const SAMPLE_RATE = 48_000;
const KIT_URL = (kit) =>
  `https://raw.githubusercontent.com/raphaelsalaja/audio/main/.web-kits/${kit}.json`;

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};
const kit = opt("kit", "core");
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outDirArg = opt("out", join(repoRoot, "Resources", "Sounds"));
const outDir = isAbsolute(outDirArg) ? outDirArg : resolve(process.cwd(), outDirArg);

async function loadKit() {
  if (kit.endsWith(".json")) {
    const p = isAbsolute(kit) ? kit : resolve(process.cwd(), kit);
    return JSON.parse(await readFile(p, "utf8"));
  }
  const res = await fetch(KIT_URL(kit));
  if (!res.ok) throw new Error(`fetch ${KIT_URL(kit)} → ${res.status}`);
  return res.json();
}

// delay + attack + decay + release (+ tail so the release finishes cleanly).
function estimateDuration(def) {
  const layers = def.layers ?? [{ envelope: def.envelope, delay: def.delay }];
  let max = 0;
  for (const layer of layers) {
    const env = layer.envelope ?? { decay: 0.5 };
    const total = (layer.delay ?? 0) + (env.attack ?? 0) + env.decay + (env.release ?? 0);
    if (total > max) max = total;
  }
  return Math.max(0.2, max + 0.15);
}

// 16-bit PCM WAV, as in the library's bufferToWav().
function bufferToWav(buffer) {
  const numChannels = buffer.numberOfChannels;
  const dataSize = buffer.length * numChannels * 2;
  const ab = new ArrayBuffer(44 + dataSize);
  const view = new DataView(ab);
  const str = (off, s) => { for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i)); };
  str(0, "RIFF"); view.setUint32(4, 36 + dataSize, true); str(8, "WAVE");
  str(12, "fmt "); view.setUint32(16, 16, true); view.setUint16(20, 1, true);
  view.setUint16(22, numChannels, true); view.setUint32(24, buffer.sampleRate, true);
  view.setUint32(28, buffer.sampleRate * numChannels * 2, true);
  view.setUint16(32, numChannels * 2, true); view.setUint16(34, 16, true);
  str(36, "data"); view.setUint32(40, dataSize, true);
  const channels = [];
  for (let ch = 0; ch < numChannels; ch++) channels.push(buffer.getChannelData(ch));
  let off = 44;
  for (let i = 0; i < buffer.length; i++)
    for (let ch = 0; ch < numChannels; ch++) {
      const s = Math.max(-1, Math.min(1, channels[ch][i]));
      view.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7fff, true);
      off += 2;
    }
  return new Uint8Array(ab);
}

const data = await loadKit();
await mkdir(outDir, { recursive: true });
for (const name of SOUNDS) {
  const def = data.sounds[name];
  if (!def) throw new Error(`kit "${kit}" has no sound "${name}"`);
  const buffer = await renderToBuffer(def, {
    duration: estimateDuration(def),
    sampleRate: SAMPLE_RATE,
    numberOfChannels: 1,
  });
  await writeFile(join(outDir, `${name}.wav`), bufferToWav(buffer));
  console.log(`baked ${name}.wav`);
}
console.log(`✓ ${SOUNDS.length} sounds from kit "${kit}" → ${outDir}`);
