# Changelog

## [Unreleased]

### Added

- **On-device self-test** (MOB-418). `MobVideo.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  calls `video_probe/1` on a path that does not exist and waits up to 5 s
  for the native answer: the NIF must return `:ok` and the native worker
  (iOS: the GCD queue's `fileExistsAtPath:` check; Android: the Kotlin
  `MobVideoBridge` worker's `File.exists()` check, delivered through the
  `nativeDeliverVideoError` JNI thunk) must send
  `{:video, :error, :not_found}`. Anything else, silence, or the stub's
  `nif_not_loaded` is a failure; no hardware is involved, so there is no
  skip. The probe runs in a throwaway process, so a stale `{:video, _, _}`
  in the caller's mailbox can neither pass it nor be consumed. Run it with
  `mix mob.selftest` from a host app (mob_dev 0.7.17).
  Requires mob 0.9.15; `mob_version` in the manifest is now `~> 0.9`.

### Changed

- **Android: `video_probe/1` reports an unregistered bridge.** The Zig NIF
  returns `{:error, :bridge_not_registered}` instead of calling into JNI
  with a null class / method ID when `MobVideoBridge.register()` never ran
  or the `video_probe` method-ID lookup returned null. `MobVideo.probe/2` is
  unchanged (it ignores the return value); the self-test turns it into a
  failure.

## [0.1.1] - 2026-09-30

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

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.

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
