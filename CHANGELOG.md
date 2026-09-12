# Changelog

## [Unreleased]

### Fixed

- **iOS `clip/4` and `extract_audio/3` no longer read a freed pointer**
  (MOB-88). Both operations captured `dst.UTF8String` (a `const char *`
  whose lifetime is tied to the NSString it came from) into the
  `AVAssetExportSession` completion block. Once `do_clip` /
  `do_extract_audio` returned, the caller's NSString could be released
  by ARC before the async export finished, leaving the block with a
  dangling C pointer that was then passed to
  `enif_make_new_binary` — undefined behavior, sometimes a garbled path
  in the delivered term, sometimes a crash. The completion blocks now
  capture the NSString itself (retained by ARC for the block's
  lifetime) and call `.UTF8String` inside the block, so the pointer is
  only dereferenced while the string is alive. iOS-only — Android takes
  a different path via the Kotlin bridge.

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
