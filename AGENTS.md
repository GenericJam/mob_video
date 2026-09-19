# AGENTS.md — orientation for AI agents working on mob_video

You're in **mob_video**, a Mob plugin for on-device video processing — clip, probe, thumbnail, extract-audio — driven by the platform's own toolkits (`AVFoundation` on iOS, `MediaExtractor` / `MediaMuxer` / `MediaMetadataRetriever` on Android). No ffmpeg. See [`decisions/2026-06-16-platform-apis-not-ffmpeg.md`](decisions/2026-06-16-platform-apis-not-ffmpeg.md) for why.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — mob's three-repo topology, the plugin manifest schema, `Mob.Screen` conventions, how to drive a running app from your session, and the cross-cutting pre-empt-failure rules. This file is mob_video-specific.

> **Keep this file current.** When you change a message shape, add or remove an operation, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_video is, in one paragraph

A cross-platform capability plugin whose only public surface is the `MobVideo` module. Four asynchronous operations — `probe/2`, `clip/4`, `thumbnail/4`, `extract_audio/3` — each returns the `Mob.Socket.t()` immediately after firing a NIF and delivers its result later as a `{:video, kind, payload}` message to the calling screen's `handle_info/2`. On iOS the NIF is Objective-C and drives `AVURLAsset` / `AVAssetExportSession` passthrough / `AVAssetImageGenerator` / a single-track `AVMutableComposition`. On Android the NIF is Zig, which caches JNI method ids for the Kotlin `MobVideoBridge` (uses `MediaExtractor` + `MediaMuxer` + `MediaMetadataRetriever`) and runs everything on a single-thread executor so BEAM scheduler threads never block. Both sides build the same result-message terms and use the same numeric error codes (0 not_found, 1 unsupported, 2 io_error, 3 bad_range) so the Elixir seam is platform-independent.

## What mob_video is NOT

* **Not [`mob_camera`](https://hexdocs.pm/mob_camera).** That's live camera capture with a preview session (photos + recording). mob_video processes videos that already exist on disk; it never opens a camera.
* **Not [`mob_photos`](https://hexdocs.pm/mob_photos).** That's the system photo/video *picker* — it hands you a local file path plus the required storage/media permission. mob_video is the next step: it consumes that path and probes / clips / thumbnails / extracts audio.
* **Not [`mob_screencast`](https://hexdocs.pm/mob_screencast).** That's live screen capture as an H264 stream. Different lifecycle, different codec surface, different permission model.
* **Not a re-encoder.** Every operation is stream-copy or a single-frame decode. Transcoding, filters, overlays and concat-across-codecs need a software codec pipeline (ffmpeg) with real size/licensing/performance cost — deliberately out of scope. If a real need appears, an ffmpeg backend slots in behind the same `MobVideo` API. See the decision record.

## The message contract is the API

The zig deliver-thunks, the Kotlin `nativeDeliver*` externs, the ObjC `send_*` builders, and the `MobVideo` moduledoc are one contract. Change them together.

Result shapes (from the moduledoc):

    {:video, :info, %{duration_ms:, width:, height:, rotation:,
                      has_audio:, bitrate:, frame_rate:}}
    {:video, :clipped, %{path:, duration_ms:}}
    {:video, :thumbnail, %{path:, width:, height:}}
    {:video, :audio_extracted, %{path:}}
    {:video, :error, reason}   # :not_found | :unsupported | :io_error | :bad_range

Numeric-only error codes keep the native thunks string-free except for output paths. A new failure mode means picking a new integer, adding it to the enum on both sides, and adding an atom in both `send_error` / `nativeDeliverVideoError` translators.

## Anatomy of the plugin

* `lib/mob_video.ex` — public API + canonical @moduledoc (operations, message shapes, permissions, out-of-scope notes).
* `lib/mob_video/demo_screen.ex` — `MobVideo.DemoScreen`, a sample `Mob.Screen` declared in the manifest's `:screens` so a generated app can kick the tires immediately. Delete it (and the manifest entry) in a real app.
* `src/mob_video_nif.erl` — Erlang NIF stub. `on_load` tolerates a load failure so host dev builds (no native linked) fall back to `nif_error(:nif_not_loaded)` instead of crashing at boot.
* `priv/mob_plugin.exs` — the plugin manifest. Declares one screen, two NIF entries (both under module `:mob_video_nif`, one per platform), iOS frameworks (`AVFoundation`, `CoreMedia`, `CoreGraphics`, `ImageIO`, `MobileCoreServices`), the Android bridge class (`io.mob.video.MobVideoBridge`), and a manifest-merged `READ_MEDIA_VIDEO` permission for shared-store paths on Android 13+. **No** runtime permission capability — file processing needs none.
* `priv/native/ios/mob_video_nif.m` — iOS NIF, Objective-C (`-fobjc-arc`), `ERL_NIF_INIT` registers as `:mob_video_nif`.
* `priv/native/jni/mob_video_nif.zig` — Android NIF, Zig. Caches Kotlin method ids at register time; exports the `nativeRegister` + `nativeDeliver*` thunks the Kotlin bridge calls back into.
* `priv/native/android/MobVideoBridge.kt` — the real Android work. Runs on a single-thread executor so the BEAM scheduler thread never blocks; results are delivered by pid.
* `priv/mob_plugin.pub` / `priv/mob_plugin.sig` — first-party signing artifacts. Signed by the shared mob key on release.
* `decisions/` — ADRs. Read `2026-06-16-platform-apis-not-ffmpeg.md` first; it's the reason this plugin exists in this shape.

## Cross-repo work

**mob (framework):** `Mob.Screen`, `Mob.Socket`, `Mob.Storage.dir/1` (used by callers for `dst` paths under app-writable storage) and the plugin loader that reads `priv/mob_plugin.exs` all live in mob. If a new operation needs to be reached from something other than a screen (e.g. a background task), check with Kevin — the `socket` seam is deliberate.

**mob_dev:** hosts `MobDev.Plugin.Manifest` + `MobDev.Plugin.Validator` (which the test suite exercises), the pre-publish signing tool (`mix mob.plugin.sign`), and the native build pipeline that copies `priv/native/*` into the host's build tree and links the platform-appropriate NIF. Manifest schema changes land in mob_dev first, then this plugin.

**mob_photos:** the intended source of `src` paths that come from the gallery. On Android 13+ that path is under the shared media store — the `READ_MEDIA_VIDEO` permission this plugin manifest-merges lets a host that already picked through `mob_photos` hand the resulting path straight to `MobVideo` without extra plumbing.

## Testing

Elixir suite (host, no native linked):

```bash
mix deps.get
MIX_ENV=test mix test
```

What the suite covers today:

* Plugin manifest loads + validates via `MobDev.Plugin.{Manifest, Validator}`.
* Manifest tiering (tier 3 because the demo screen lives here).
* Cross-platform NIF shape: one module, iOS/`:objc` + Android/`:zig`.
* Every declared native source dir + Kotlin bridge file actually exists.
* The `.erl` stub loads on a host build and every documented arity is exported.
* Host fallback path: calling a NIF with no native linked raises `nif_not_loaded` cleanly.
* `MobVideo` exports every operation the moduledoc documents.

**Native code is not exercised by `mix test`.** It links only inside a host `--native` build. Verify a real op on a device before trusting a native change: activate mob_video in a host app, `mix mob.deploy --native --device <serial>`, then drive the demo screen (`/mob_video/demo`) with a `sample.mp4` in the app's documents directory.

Video-encoding behaviour varies by platform: what Android's `MediaMuxer` accepts is not identical to what `AVAssetExportSession` accepts, and codec support varies across OEMs. Verify on both a real Android device (Kevin has a Moto G Power 5G 2024) and a real iPhone before shipping a fix that touches the codec surface — the simulator/emulator paths hide meaningful failure modes.

## The pre-empt-failure rules that matter here

1. **The four-way contract is real.** ObjC builder + Zig deliver-thunk + Kotlin `nativeDeliver*` extern + Elixir moduledoc must all describe the same term. If you edit any one, edit the others in the same commit and run the test suite (manifest agreement) plus a native build on both platforms. Silent drift here delivers wrong-shape messages that only surface on device.
2. **Numeric error codes are a discipline, not a shortcut.** New failure = new integer on both sides + new atom translator. Sneaking a string across the JNI or `enif_send` boundary reintroduces the coupling the numeric convention exists to prevent.
3. **`src` is a local file path — no URLs, no content-URIs, no bookmarks.** The permission model assumes the app can already read the path. If a caller has a `content://` URI from the picker, they resolve it through `mob_photos` first, then hand this plugin the resulting local path.
4. **`dst` goes under app storage.** Use `Mob.Storage.dir(:cache)` (or `:documents`) — writing to arbitrary paths hits sandbox failures that surface as `:io_error` and waste debug cycles.
5. **Every op is asynchronous — always.** No synchronous variant exists. A screen that needs the result before proceeding awaits the `{:video, ...}` message; do not paper over it with a receive loop that blocks the LiveView process.
6. **Don't add re-encoding here.** If a use case genuinely needs it, that's a new plugin (or a new backend behind this API), not a feature bolted onto the existing operations. The decision record exists to prevent this.

## Pre-commit + release

```bash
mix format
mix credo --strict          # ExSlop + jump_credo_checks, mirrors mob core
mix compile --warnings-as-errors
mix test
# native, when native sources changed:
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
mix mob.validate_plugin     # from a host app
```

Activate `.githooks` once with `mix setup` (or `git config core.hooksPath .githooks`); the pre-push hook re-runs format + credo strict + fast tests.

Release: `mix.exs` version is the trigger. Bump it, update `CHANGELOG.md`, sign (`mix mob.plugin.sign`), then push master — CI publishes to Hex and verifies `MOB_PLUGIN_SIGN_KEY` matches the committed `priv/mob_plugin.pub`. **Get a `--native` build green on both a real Android device and a real iPhone before releasing** — a published version is permanent.
