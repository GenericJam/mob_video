defmodule MobVideo.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One native round trip, no UI, nothing written: `video_probe/1` on a path
  that does not exist, then wait for what the native side sends back.

    1. The NIF must answer `:ok` synchronously. The host stub raises
       `nif_not_loaded` instead (the native library was not linked); on
       Android the Zig NIF answers `{:error, :bridge_not_registered}` when
       `MobVideoBridge.register()` never ran or the `video_probe` method-ID
       lookup failed, and `:error` when it could not get a JNI env. Each of
       those is a failure.
    2. The native worker must then deliver `{:video, :error, :not_found}` to
       the caller within 5 s.
       * iOS (simulator and device): `nif_video_probe` dispatches `do_probe`
         onto the plugin's serial GCD queue, which checks
         `-[NSFileManager fileExistsAtPath:]` and sends the error term with
         `enif_send`. The answer proves the Objective-C NIF is linked and its
         queue and delivery path run.
       * Android (emulator and device): the Zig NIF calls the Kotlin
         `MobVideoBridge.video_probe` through the cached JNI method ID; the
         bridge's single-thread worker checks `File(src).exists()` and calls
         back through the `nativeDeliverVideoError` JNI thunk with code 0. The
         answer proves `nif_init` ran, the bridge class registered and the
         Kotlin → Zig delivery thunk is linked.

  The missing file needs no camera, codec, media or permission, so the same
  answer is expected on an iOS simulator, an Android emulator and a physical
  device; there is no skip. Any other delivery (`:info` for a file that should
  not exist, another error reason) is a failure, as is silence: the delivery
  never reached the calling pid, or the native queue is still busy with a long
  host clip/extract after 5 s. (On Android a Kotlin `Error` on the worker, such
  as an `UnsatisfiedLinkError` from an unlinked delivery thunk, kills the app
  instead; the runner reports that as a failure too.)

  The probe and the wait run in a throwaway process: the native side answers
  `enif_self` of the caller, so only this call's answer can arrive there, a
  stale `{:video, _, _}` in the runner's mailbox cannot make it pass, a host
  screen's pending results are not consumed, and a late answer dies with the
  process.
  """
  @behaviour Mob.Plugin.SelfTest

  @missing_src "/mob_video-selftest-no-such-file.mp4"
  @answer_timeout 5_000

  @impl true
  def run(ctx), do: run(ctx, :mob_video_nif)

  @doc false
  # `nif` is the NIF module, so tests can pass a stub; `timeout` is how long to
  # wait for the native delivery.
  @spec run(Mob.Plugin.SelfTest.ctx(), module(), non_neg_integer()) ::
          Mob.Plugin.SelfTest.result()
  def run(%{platform: platform}, nif, timeout \\ @answer_timeout) do
    {pid, ref} = spawn_monitor(fn -> exit({:result, probe(platform, nif, timeout)}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:result, result}} ->
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:fail, "video_probe/1 on #{platform} crashed the probe process: #{inspect(reason)}"}
    end
  end

  defp probe(platform, nif, timeout) do
    case nif.video_probe(@missing_src) do
      :ok ->
        await_answer(platform, timeout)

      {:error, :bridge_not_registered} ->
        {:fail,
         "video_probe/1 on #{platform} returned {:error, :bridge_not_registered}: " <>
           "the Kotlin MobVideoBridge was never registered (MobVideoBridge.register() " <>
           "did not run or the video_probe method-ID lookup failed), expected :ok"}

      other ->
        {:fail, "video_probe/1 on #{platform} returned #{inspect(other)}, expected :ok"}
    end
  rescue
    e in ErlangError ->
      {:fail,
       "mob_video_nif is not linked into this build: video_probe/1 raised " <>
         Exception.message(e)}
  end

  defp await_answer(platform, timeout) do
    receive do
      {:video, :error, :not_found} ->
        :pass

      {:video, kind, payload} ->
        {:fail,
         "video_probe/1 on #{platform} of the missing file #{@missing_src} delivered " <>
           "#{inspect({:video, kind, payload})}, expected {:video, :error, :not_found}"}
    after
      timeout ->
        {:fail,
         "video_probe/1 on #{platform} returned :ok but no {:video, _, _} answer arrived " <>
           "in #{timeout} ms, expected {:video, :error, :not_found} from the native worker"}
    end
  end
end
