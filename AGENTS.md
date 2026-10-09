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
* `MobVideo.SelfTest` (the on-device self-test) classifies every native answer to `video_probe/1` of a missing file, against stub NIF modules; the manifest declares it as `selftest:`.

**Native code is not exercised by `mix test`.** It links only inside a host `--native` build. Verify a real op on a device before trusting a native change: activate mob_video in a host app, `mix mob.deploy --native --device <serial>`, then drive the demo screen (`/mob_video/demo`) with a `sample.mp4` in the app's documents directory.

The cheapest on-device check is the self-test: `mix mob.selftest` from a host app that depends on mob_video (mob_dev >= 0.7.17). It proves the NIF, the Android bridge registration and the delivery path answer, not that a codec works. On Android, `video_probe/1` returns `{:error, :bridge_not_registered}` when the bridge never registered; the public API ignores it, the self-test fails on it.

Video-encoding behaviour varies by platform: what Android's `MediaMuxer` accepts is not identical to what `AVAssetExportSession` accepts, and codec support varies across OEMs. Verify on both a real Android device (Kevin has a Moto G Power 5G 2024) and a real iPhone before shipping a fix that touches the codec surface — the simulator/emulator paths hide meaningful failure modes.

## The pre-empt-failure rules that matter here

1. **The four-way contract is real.** ObjC builder + Zig deliver-thunk + Kotlin `nativeDeliver*` extern + Elixir moduledoc must all describe the same term. If you edit any one, edit the others in the same commit and run the test suite (manifest agreement) plus a native build on both platforms. Silent drift here delivers wrong-shape messages that only surface on device.
2. **Numeric error codes are a discipline, not a shortcut.** New failure = new integer on both sides + new atom translator. Sneaking a string across the JNI or `enif_send` boundary reintroduces the coupling the numeric convention exists to prevent.
3. **`src` is a local file path — no URLs, no content-URIs, no bookmarks.** The permission model assumes the app can already read the path. If a caller has a `content://` URI from the picker, they resolve it through `mob_photos` first, then hand this plugin the resulting local path.
4. **`dst` goes under app storage.** Use `Mob.Storage.dir(:cache)` (or `:documents`) — writing to arbitrary paths hits sandbox failures that surface as `:io_error` and waste debug cycles.
5. **Every op is asynchronous — always.** No synchronous variant exists. A screen that needs the result before proceeding awaits the `{:video, ...}` message; do not paper over it with a receive loop that blocks the LiveView process.
6. **Don't add re-encoding here.** If a use case genuinely needs it, that's a new plugin (or a new backend behind this API), not a feature bolted onto the existing operations. The decision record exists to prevent this.

## Worktrees

**Default assumption: work happens in a git worktree.** Kevin runs multiple agents in parallel; each task in its own worktree prevents conflicts.

If a task is assigned to you and worktree usage isn't mentioned, ask:

> "Should I use a worktree for this?"

Yes for anything non-trivial or that touches native code. In-place is fine for a single-file doc edit, one-line config change, or a version bump.

The git stash stack is shared across worktrees — never bare `git stash` / `git stash pop`.

## Pre-commit checklist

Before committing, run all of these; the full suite must pass:

```bash
mix format
mix credo --strict          # whole tree; ExSlop + jump_credo_checks, mirrors mob core
mix compile --warnings-as-errors
mix test                    # full suite must pass
```

If native sources changed:

```bash
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
mix mob.validate_plugin     # from a host app
```

Activate `.githooks` once with `mix setup` (or `git config core.hooksPath .githooks`); the pre-push hook re-runs format + credo strict + fast tests on every push.

### Tests are part of the change

New behaviour ships with a test unless the change is small enough that a test would only restate it. The bar is: **would this test fail if the fix were reverted?** Check by reverting it.

For mob_video specifically:

* Any change to the manifest (NIF entries, screens, permissions, frameworks) needs an assertion in the manifest test group — those tests are what catch cross-repo drift with `MobDev.Plugin.Validator`.
* Any change to the `mob_video_nif.erl` stub needs the export-arity check to still match the moduledoc's operation signatures.
* Any change to a message shape needs the moduledoc + ObjC builder + Zig thunk + Kotlin extern updated together in the same commit.

`mix test` does not exercise native code — it links only inside a host `--native` build. A native change is not verified until it runs on a real device.

### Decision log — check both directions

Before committing, ask two questions:

**Does this need a new record?** Anything non-obvious: a tradeoff, a workaround, a convention. The commit message explaining a decision means that decision belongs in `decisions/` where it's findable. The current record on the ffmpeg boundary is the model — Context / Decision / Consequences, append never edit.

**Does this INVALIDATE an existing record?** More dangerous half. Grep `decisions/` for the mechanism you are changing before you commit. Correct in place with a note about what was wrong, don't quietly delete.

### Adversarial review — before every non-trivial commit

Spawn a subagent, point it at the diff, tell it to find defects rather than approve.

Especially for this plugin:

* **Message-contract drift.** The four sides (ObjC, Zig, Kotlin, moduledoc) must agree exactly. A subagent reading only the diff often catches a keyset or type mismatch across the JNI/`enif_send` boundary that a human editing all four in one pass will miss.
* **Error-code fidelity.** New failure modes must add a new integer on both sides plus a translator to a new atom. Reusing an existing code with a slightly different meaning is silent and cumulative.
* **Threading on the native side.** Android's single-thread worker is what keeps the BEAM scheduler unblocked; iOS's background dispatch does the same. A change that quietly runs work on a scheduler thread is a latent scheduler stall.

Skip only for: formatting, a typo, a version bump, a changelog edit.

## Release flow

Canonical process in [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). mob_video specifics:

* `@version` in `mix.exs` is the trigger. Bump it, update `CHANGELOG.md` in the same commit, sign (`mix mob.plugin.sign`), then push master; CI handles tag / GH-release / hex-publish, and (per commit `b5d4c08`) verifies `MOB_PLUGIN_SIGN_KEY` matches the committed `priv/mob_plugin.pub` before publishing.
* **Never ship without physical-device verification on both platforms.** Get a `--native` build green on both a real Android device and a real iPhone before releasing — a published version is permanent. Simulators and emulators lie about codec / muxer behaviour. Kevin has a Moto G Power 5G 2024 and an iPhone for real-device runs.

## When you're flailing

Native video work fails in ways `mix test` can't see. Reach for the richer signal first:

1. **Drive the demo screen from a live host.** Activate mob_video, `mix mob.deploy --native --device <serial>`, drop a `sample.mp4` in the app's Documents dir, tap through the demo. The `{:video, ...}` messages arrive at `handle_info/2` — watch them in `mix mob.connect`.
2. **Instrument the native seam, not the Elixir seam.** The Elixir side already returns `:ok` immediately; the interesting behaviour is on the other side of the NIF. Add a log line at the boundary in the ObjC or Kotlin file that's misbehaving, redeploy, then decide the next change.
3. **Isolate by operation.** The four ops share the delivery path but almost nothing else — if `probe` is fine and `clip` is broken, that's `MediaMuxer` / `AVAssetExportSession`, not JNI or `enif_send`.
