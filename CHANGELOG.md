# Changelog

## 0.1.0

Initial release. On-device video processing backed entirely by the platform
toolkits (no ffmpeg):

- `MobVideo.probe/2` — clip metadata (duration, dimensions, rotation, audio
  presence, bitrate, frame rate).
- `MobVideo.clip/4` — cut a time range by stream copy (lossless, no re-encode).
- `MobVideo.thumbnail/4` — extract a single frame as a JPEG.
- `MobVideo.extract_audio/3` — pull the audio track into its own file.

Android via `MediaExtractor`/`MediaMuxer`/`MediaMetadataRetriever`; iOS via
`AVFoundation` (`AVAssetExportSession` passthrough, `AVAssetImageGenerator`).
