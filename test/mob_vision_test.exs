defmodule MobVisionTest do
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

    test "classifies as tier 1 (NIF plugin)", %{manifest: m} do
      assert Manifest.tier(m) == 1
    end

    test "passes the full pre-publish validator (paths, NIF modules)", %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_vision_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_vision_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "declares NO runtime-permission capability — image OCR needs none",
         %{manifest: m} do
      refute Map.has_key?(m, :permissions)
    end

    test "declares NO android uses-permission — reads a file the app already has",
         %{manifest: m} do
      refute Map.has_key?(m.android, :permissions)
    end

    test "carries the ML Kit text-recognition gradle dep (and no CameraX — no live camera here)",
         %{manifest: m} do
      assert "com.google.mlkit:text-recognition:16.0.1" in m.android.gradle_deps
      refute Enum.any?(m.android.gradle_deps, &String.contains?(&1, "androidx.camera"))
    end

    test "iOS links the Vision framework and needs no plist key (no camera/photo access)",
         %{manifest: m} do
      assert m.ios.frameworks == ["Vision"]
      refute Map.has_key?(m.ios, :plist_keys)
    end

    test "every native source dir + the Kotlin bridge the manifest references exists",
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
      assert Code.ensure_loaded?(:mob_vision_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_vision_nif.module_info(:exports)

      for fa <- [recognize_text: 1] do
        assert fa in exports, "#{inspect(fa)} missing from mob_vision_nif exports"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_vision_nif.recognize_text(MobVision.encode_request("/tmp/x.png", []))
      end
    end
  end

  describe "public API surface" do
    test "exports recognize_text/2 and /3" do
      exports = MobVision.__info__(:functions)
      assert {:recognize_text, 2} in exports
      assert {:recognize_text, 3} in exports
    end

    test "encode_request/2 builds the JSON the NIF expects, stringifying language hints" do
      json = MobVision.encode_request("/path/to/img.png", languages: [:en, "fr"])
      decoded = :json.decode(json)
      assert decoded == %{"path" => "/path/to/img.png", "languages" => ["en", "fr"]}
    end

    test "encode_request/2 defaults languages to an empty list" do
      decoded = :json.decode(MobVision.encode_request("/a.jpg", []))
      assert decoded == %{"path" => "/a.jpg", "languages" => []}
    end
  end
end
