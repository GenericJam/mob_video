defmodule MobVideo.SelfTestTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobVideo.SelfTest

  @plugin_dir Path.expand("../..", __DIR__)
  @ios %{platform: :ios, device: :simulator}
  @android %{platform: :android, device: :emulator}

  # Stub NIFs. video_probe/1 answers synchronously; the ones that return :ok
  # deliver like the native worker would (to the caller, from another process).
  defmodule NotFoundNif do
    def video_probe(src) do
      if File.exists?(src), do: raise("the self-test probed an existing file: #{src}")
      deliver({:video, :error, :not_found})
    end

    def deliver(msg) do
      caller = self()
      spawn(fn -> send(caller, msg) end)
      :ok
    end
  end

  defmodule InfoNif do
    def video_probe(_src) do
      NotFoundNif.deliver({:video, :info, %{duration_ms: 1_000, width: 640, height: 480}})
    end
  end

  defmodule UnsupportedNif do
    def video_probe(_src), do: NotFoundNif.deliver({:video, :error, :unsupported})
  end

  defmodule SilentNif do
    def video_probe(_src), do: :ok
  end

  defmodule UnregisteredNif do
    def video_probe(_src), do: {:error, :bridge_not_registered}
  end

  defmodule NoJniEnvNif do
    def video_probe(_src), do: :error
  end

  defmodule NotLoadedNif do
    def video_probe(_src), do: :erlang.nif_error(:nif_not_loaded)
  end

  defmodule LateNif do
    def video_probe(_src) do
      caller = self()

      spawn(fn ->
        Process.sleep(50)
        send(caller, {:video, :error, :not_found})
      end)

      :ok
    end
  end

  defmodule CrashNif do
    def video_probe(_src), do: raise("boom")
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == MobVideo.SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "a missing file answered with {:video, :error, :not_found} passes on both platforms" do
    assert SelfTest.run(@ios, NotFoundNif, 1_000) == :pass
    assert SelfTest.run(@android, NotFoundNif, 1_000) == :pass
  end

  test "an unregistered Android bridge fails, naming the bridge" do
    assert {:fail, reason} = SelfTest.run(@android, UnregisteredNif, 1_000)
    assert reason =~ "{:error, :bridge_not_registered}"
    assert reason =~ "MobVideoBridge was never registered"
  end

  test "any other synchronous answer fails, saying what came back" do
    assert SelfTest.run(@android, NoJniEnvNif, 1_000) ==
             {:fail, "video_probe/1 on android returned :error, expected :ok"}
  end

  test "a native library that is not linked fails, naming the NIF" do
    assert {:fail, reason} = SelfTest.run(@ios, NotLoadedNif, 1_000)
    assert reason =~ "mob_video_nif is not linked"
    assert reason =~ "nif_not_loaded"
  end

  test "a delivery other than :not_found for the missing file fails, quoting it" do
    assert {:fail, reason} = SelfTest.run(@ios, InfoNif, 1_000)
    assert reason =~ "delivered {:video, :info,"
    assert reason =~ "expected {:video, :error, :not_found}"

    assert {:fail, reason} = SelfTest.run(@android, UnsupportedNif, 1_000)
    assert reason =~ "delivered {:video, :error, :unsupported}"
  end

  test ":ok with no delivery fails after the timeout" do
    assert {:fail, reason} = SelfTest.run(@android, SilentNif, 0)
    assert reason =~ "returned :ok but no {:video, _, _} answer arrived in 0 ms"
  end

  test "a stale answer in the caller's mailbox neither passes the test nor gets consumed" do
    send(self(), {:video, :error, :not_found})
    send(self(), {:video, :clipped, %{path: "/host/clip.mp4", duration_ms: 1_000}})

    assert {:fail, _} = SelfTest.run(@android, SilentNif, 50)
    assert_received {:video, :error, :not_found}
    assert_received {:video, :clipped, %{path: "/host/clip.mp4"}}
  end

  test "a late answer after the timeout does not reach the caller" do
    assert {:fail, _} = SelfTest.run(@ios, LateNif, 0)
    refute_receive {:video, _, _}, 200
  end

  test "a NIF that crashes with something other than an ErlangError fails, quoting it" do
    {result, _log} = with_log(fn -> SelfTest.run(@android, CrashNif, 1_000) end)
    assert {:fail, reason} = result
    assert reason =~ "video_probe/1 on android crashed the probe process"
    assert reason =~ "boom"
  end

  test "every branch is a result the runner accepts" do
    for nif <- [
          NotFoundNif,
          InfoNif,
          UnsupportedNif,
          SilentNif,
          UnregisteredNif,
          NoJniEnvNif,
          NotLoadedNif,
          CrashNif
        ] do
      {result, _log} = with_log(fn -> SelfTest.run(@android, nif, 200) end)
      assert Mob.Plugin.SelfTest.result?(result), inspect(nif)
    end
  end

  test "on a host with only the .erl stub, run/1 fails instead of raising" do
    assert {:fail, reason} = SelfTest.run(@android)
    assert reason =~ "mob_video_nif is not linked"
    assert Mob.Plugin.SelfTest.result?({:fail, reason})
  end
end
