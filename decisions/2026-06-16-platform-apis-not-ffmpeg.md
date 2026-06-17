# Platform video APIs, not ffmpeg

- Date: 2026-06-16
- Status: accepted

## Context

Mob apps want video features (a clipper was the prompting idea). The instinct is
to bundle ffmpeg so "anything video" is possible. On mobile that is a heavy bet:
ffmpeg adds tens of MB per arch, its useful encoders (x264/x265) make it GPL —
which conflicts with App Store distribution — it needs a hand-rolled
Android+iOS cross-compile now that ffmpeg-kit is archived, and its software video
encode is slow and battery-hungry. It also cannot be added at runtime to a mob
app (native code must be bundled at build time), so it would weigh every build.

## Decision

Ship the operations the platform already does natively, and only those:
`probe`, `clip`, `thumbnail`, `extract_audio`. Each is a stream-copy or a
single-frame decode — `MediaExtractor`/`MediaMuxer`/`MediaMetadataRetriever` on
Android, `AVFoundation` on iOS. No ffmpeg. The clip is a lossless remux with no
re-encode.

## Consequences

- Small, no licensing problem, hardware-accelerated, lossless clips.
- Re-encoding, filters, overlays, and concat-across-codecs are out of scope.
  When a real need appears, an `ffmpeg` backend slots in behind this same
  `MobVideo` API rather than being a precondition for the common 80%.
- The 0.1 surface is intentionally narrow; grow it from real usage, not on spec.
