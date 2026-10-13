defmodule MobVideo.RefusedCallTest do
  # Not async: the stub NIF goes into the :mob_video app env, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule UnregisteredBridgeNif do
    def video_probe(_src), do: {:error, :bridge_not_registered}
    def video_clip(_src, _dst, _start_ms, _end_ms), do: {:error, :bridge_not_registered}
    def video_thumbnail(_src, _dst, _at_ms, _max_width), do: {:error, :bridge_not_registered}
    def video_extract_audio(_src, _dst), do: {:error, :bridge_not_registered}
  end

  defmodule AcceptingNif do
    def video_probe(_src), do: :ok
    def video_clip(_src, _dst, _start_ms, _end_ms), do: :ok
    def video_thumbnail(_src, _dst, _at_ms, _max_width), do: :ok
    def video_extract_audio(_src, _dst), do: :ok
  end

  setup do
    on_exit(fn -> Application.delete_env(:mob_video, :nif) end)
    %{socket: Mob.Socket.new(__MODULE__)}
  end

  test "a refused call is logged with the function and reason, and still returns the socket",
       %{socket: socket} do
    Application.put_env(:mob_video, :nif, UnregisteredBridgeNif)

    for {name, fun} <- calls() do
      log = capture_log(fn -> assert fun.(socket) == socket end)
      assert log =~ "MobVideo.#{name}"
      assert log =~ ":bridge_not_registered"
    end
  end

  test "an accepted call logs nothing", %{socket: socket} do
    Application.put_env(:mob_video, :nif, AcceptingNif)

    for {_name, fun} <- calls() do
      assert capture_log(fn -> assert fun.(socket) == socket end) == ""
    end
  end

  defp calls do
    [
      {"probe/2", &MobVideo.probe(&1, "/tmp/in.mp4")},
      {"clip/4", &MobVideo.clip(&1, "/tmp/in.mp4", "/tmp/out.mp4")},
      {"thumbnail/4", &MobVideo.thumbnail(&1, "/tmp/in.mp4", "/tmp/out.jpg")},
      {"extract_audio/3", &MobVideo.extract_audio(&1, "/tmp/in.mp4", "/tmp/out.m4a")}
    ]
  end
end
