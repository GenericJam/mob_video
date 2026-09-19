# mob_video — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view. Together they cover the plugin anatomy, the four-way message contract (ObjC + Zig + Kotlin + Elixir moduledoc), what mob_video is *not* (peer-plugin boundaries), and cross-repo work with mob / mob_dev / mob_photos. This file goes deeper on Claude Code-specific workflow detail.

> **Keep AGENTS.md up to date** when you change a message shape, add or remove an operation, or hit a new gotcha. Out-of-date guidance there causes wrong decisions downstream — fix it in the same commit, not in a follow-up.

## What this repo is

A cross-platform Mob capability plugin. One public surface (`MobVideo`), per-platform NIFs behind a shared numeric-error contract, four async operations (`probe`, `clip`, `thumbnail`, `extract_audio`) — all stream-copy or single-frame decode via the platform toolkits (`AVFoundation` on iOS, `MediaExtractor` / `MediaMuxer` / `MediaMetadataRetriever` on Android). **No ffmpeg** — see [`decisions/2026-06-16-platform-apis-not-ffmpeg.md`](decisions/2026-06-16-platform-apis-not-ffmpeg.md).

## Worktrees

**Default assumption: work happens in a git worktree.** Kevin runs multiple agents in parallel; each task in its own worktree prevents conflicts.

If a task is assigned to you and worktree usage isn't mentioned, ask:

> "Should I use a worktree for this?"

Yes for anything non-trivial or that touches native code. In-place is fine for a single-file doc edit, one-line config change, or a version bump.

The git stash stack is shared across worktrees — never bare `git stash` / `git stash pop`.

## Pre-commit checklist

Before committing, run all in this order:

```bash
mix test                            # full suite must pass
mix format                          # apply formatting
mix credo --strict                  # whole tree, includes ExSlop
mix compile --warnings-as-errors
```

If native sources changed:

```bash
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
mix mob.validate_plugin             # from a host app
```

Pre-push hook adds format + credo strict + fast tests on every push. Activate once:

```bash
git config core.hooksPath .githooks
```

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

* `@version` in `mix.exs` is the trigger. Push it to master; CI handles tag / GH-release / hex-publish, and (per commit `b5d4c08`) verifies `MOB_PLUGIN_SIGN_KEY` matches the committed `priv/mob_plugin.pub` before publishing.
* Update `CHANGELOG.md` in the same commit as the version bump.
* **Never ship without physical-device verification on both platforms.** Simulators and emulators lie about codec / muxer behaviour. Kevin has a Moto G Power 5G 2024 and an iPhone for real-device runs.

## When you're flailing

Native video work fails in ways `mix test` can't see. Reach for the richer signal first:

1. **Drive the demo screen from a live host.** Activate mob_video, `mix mob.deploy --native --device <serial>`, drop a `sample.mp4` in the app's Documents dir, tap through the demo. The `{:video, ...}` messages arrive at `handle_info/2` — watch them in `mix mob.connect`.
2. **Instrument the native seam, not the Elixir seam.** The Elixir side already returns `:ok` immediately; the interesting behaviour is on the other side of the NIF. Add a log line at the boundary in the ObjC or Kotlin file that's misbehaving, redeploy, then decide the next change.
3. **Isolate by operation.** The four ops share the delivery path but almost nothing else — if `probe` is fine and `clip` is broken, that's `MediaMuxer` / `AVAssetExportSession`, not JNI or `enif_send`.
