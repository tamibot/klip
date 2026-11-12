# Reparación: notas de voz largas pierden texto (macOS 27)

Síntoma: notas >30 s guardan 12-54 % del texto (5 de 16). Audio en disco íntegro.

## Causa (medida 2026-10-12, modelo large-v3-turbo, es, nota de 36.5 s, 6 corridas por config)
Decodificar >30 s en 2 ventanas con withoutTimestamps=true es NO determinista: ~50 % de las
corridas devuelve 13 de 68 palabras. Descartado: noSpeechThreshold=nil (falla igual, 3/6).

| Config | palabras por corrida |
|---|---|
| actual (sin VAD <60 s) | 13,68,13,66,68,13 |
| noSpeechThreshold=nil | 67,13,65,13,68,13 |
| VAD | 69 x6 |
| timestamps activados | 68 x6 |
Notas de 103 s / 209 s: VAD y/o timestamps → 211/211 y 404-424 palabras estables (Klip había guardado 41 y 53).

## Reparaciones aplicadas (LocalTranscriber.swift)
- R1 VAD desde 30 s (antes 60 s).
- R2 red de seguridad: clip >20 s con <0.5 palabras/s → reintento con VAD + timestamps.
## Pendiente
- Medir CPU 35 % en reposo (`sample <pid> 5`). GPU: `defaults write io.github.tamibot.klip whisperComputeUnits gpu`.
