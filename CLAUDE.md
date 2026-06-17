# mob_video — Agent Instructions

A Mob capability plugin: on-device video processing via the platform toolkits
(Android `MediaExtractor`/`MediaMuxer`/`MediaMetadataRetriever`, iOS
`AVFoundation`). **No ffmpeg** — see `decisions/` and the README for why.

## Layout

- `lib/mob_video.ex` — the public async API the host calls.
- `lib/mob_video/demo_screen.ex` — a sample `Mob.Screen` (manifest `:screens`).
- `src/mob_video_nif.erl` — the Erlang NIF stub (tolerant `on_load`).
- `priv/mob_plugin.exs` — the plugin manifest (nifs, android bridge, ios frameworks).
- `priv/native/jni/mob_video_nif.zig` — Android NIF glue (caches the Kotlin
  bridge method ids, exports the `nativeDeliver*` thunks).
- `priv/native/android/MobVideoBridge.kt` — the real Android work.
- `priv/native/ios/mob_video_nif.m` — the iOS NIF (ObjC, ERL_NIF_INIT).

## The message contract is the API

The native side and the Elixir docs MUST agree on the `{:video, ...}` tuples.
The zig deliver-thunk signatures, the Kotlin `nativeDeliver*` declarations, the
ObjC `send_*` builders, and the `MobVideo` moduledoc are one contract — change
them together. Numeric-only error codes (0 not_found, 1 unsupported, 2 io_error,
3 bad_range) keep the thunks string-free except for output paths.

## Pre-commit checklist

```bash
mix format
mix credo --strict          # ExSlop + jump_credo_checks, like mob core
mix compile --warnings-as-errors
mix test
# native (mob core's checklist):
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
mix mob.validate_plugin     # from a host app, or: pre-publish validator
```

Native code is not exercised by `mix test` (it links only inside a host
`--native` build). Verify a real op on a device before trusting a native change:
activate in a host, `mix mob.deploy --native --device <serial>`, then drive a
screen that calls `MobVideo`.

## Release

`mix.exs` version is the source of truth. Bump it, update `CHANGELOG.md`, sign
(`mix mob.plugin.sign`), then `mix hex.publish`. A published version is permanent
— get a native build green first.

## Decision log

Non-obvious calls go in `decisions/YYYY-MM-DD-slug.md` (Context / Decision /
Consequences). Append; never edit a landed one.
