defmodule MobVideoTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 3 (NIF + a demo screen)", %{manifest: m} do
      # The capability NIF alone is tier 1; the bundled demo screen (a tier-3
      # :screens section) lifts it to 3. tier/1 reports the highest section.
      assert Manifest.tier(m) == 3
    end

    test "passes the full pre-publish validator (paths, NIF modules, permissions)",
         %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_video_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_video_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "registers no runtime permission capability (file processing needs none)",
         %{manifest: m} do
      assert m.permissions == []
    end

    test "every native source dir + Kotlin bridge the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_video_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_video_nif.module_info(:exports)

      for fa <- [video_probe: 1, video_clip: 4, video_thumbnail: 4, video_extract_audio: 2] do
        assert fa in exports, "#{inspect(fa)} missing from mob_video_nif exports"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_video_nif.video_probe("/nope.mp4")
      end
    end
  end

  describe "public API surface" do
    test "exports the documented operations" do
      exports = MobVideo.__info__(:functions)

      for fa <- [probe: 2, clip: 4, thumbnail: 4, extract_audio: 3] do
        assert fa in exports, "#{inspect(fa)} missing from MobVideo"
      end
    end
  end
end
