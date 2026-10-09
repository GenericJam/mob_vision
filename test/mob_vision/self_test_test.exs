defmodule MobVision.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobVision.SelfTest

  @plugin_dir Path.expand("../..", __DIR__)
  @ctx %{platform: :android, device: :emulator}

  # Stub NIFs. recognize_text/1 runs in the caller (the test process), like the
  # real NIF, so the stubs deliver to self() the way the native side does.
  defmodule Stub do
    @moduledoc false
    # Reports the request path and whether a PNG was on disk at call time.
    def seen(json) do
      %{"path" => path} = :json.decode(json)
      png? = match?({:ok, <<137, ?P, ?N, ?G, _::binary>>}, File.read(path))
      send(self(), {:seen, path, png?})
    end
  end

  defmodule ReadsNif do
    @moduledoc false
    def recognize_text(json) do
      MobVision.SelfTestTest.Stub.seen(json)
      send(self(), {:vision, :text, "Left\n"})
      :ok
    end
  end

  defmodule MisreadsNif do
    @moduledoc false
    def recognize_text(_json) do
      send(self(), {:vision, :text, "LEET"})
      :ok
    end
  end

  defmodule NoActivityNif do
    @moduledoc false
    def recognize_text(_json) do
      send(self(), {:vision, :error, "no_activity"})
      :ok
    end
  end

  defmodule NotLoadedNif do
    @moduledoc false
    def recognize_text(json) do
      MobVision.SelfTestTest.Stub.seen(json)
      :erlang.nif_error(:nif_not_loaded)
    end
  end

  defmodule UnregisteredNif do
    @moduledoc false
    def recognize_text(_json), do: {:error, :bridge_not_registered}
  end

  defmodule ErrorAtomNif do
    @moduledoc false
    def recognize_text(_json), do: :error
  end

  defp run_with(nif, dir), do: SelfTest.run(@ctx, nif, dir: dir, timeout: 0)

  defp assert_fail(result) do
    assert {:fail, reason} = result
    assert Mob.Plugin.SelfTest.result?(result)
    reason
  end

  describe "run/3" do
    @describetag :tmp_dir

    test "the recognizer reading the word passes; the PNG it read is deleted", %{tmp_dir: dir} do
      assert run_with(ReadsNif, dir) == :pass
      assert_received {:seen, path, true}
      assert Path.dirname(path) == dir
      refute File.exists?(path)
    end

    test "text other than the word fails, quoting what was read", %{tmp_dir: dir} do
      reason = assert_fail(run_with(MisreadsNif, dir))
      assert reason =~ ~s(read "LEET")
      assert reason =~ "LEFT"
      assert File.ls!(dir) == []
    end

    test "an Android bridge without an Activity fails", %{tmp_dir: dir} do
      reason = assert_fail(run_with(NoActivityNif, dir))
      assert reason =~ "no_activity"
      assert reason =~ "setActivity"
    end

    test "nif_not_loaded fails naming the NIF and still deletes the PNG", %{tmp_dir: dir} do
      reason = assert_fail(run_with(NotLoadedNif, dir))
      assert reason =~ "mob_vision_nif is not linked"
      assert reason =~ "nif_not_loaded"
      assert_received {:seen, path, true}
      refute File.exists?(path)
    end

    test "an unregistered Kotlin bridge fails", %{tmp_dir: dir} do
      reason = assert_fail(run_with(UnregisteredNif, dir))
      assert reason =~ "bridge_not_registered"
      assert reason =~ "MobVisionBridge"
    end

    test "a return other than :ok fails, naming it", %{tmp_dir: dir} do
      reason = assert_fail(run_with(ErrorAtomNif, dir))
      assert reason =~ "returned :error, expected :ok"
    end
  end

  describe "await_answer/2" do
    test "the word passes regardless of case and whitespace" do
      send(self(), {:vision, :text, " l e f t "})
      assert SelfTest.await_answer(0, :ios) == :pass
    end

    test "no text at all fails" do
      send(self(), {:vision, :text, ""})
      assert assert_fail(SelfTest.await_answer(0, :ios)) =~ ~s(read "")
    end

    test "a native error delivery fails with the reason" do
      send(self(), {:vision, :error, "no_image"})
      assert assert_fail(SelfTest.await_answer(0, :android)) =~ "no_image"

      send(self(), {:vision, :error, "Could not create inference context"})

      assert assert_fail(SelfTest.await_answer(0, :ios)) =~
               ~s(delivered error "Could not create inference context")
    end

    test "no delivery fails instead of hanging or skipping" do
      reason = assert_fail(SelfTest.await_answer(0, :ios))
      assert reason =~ "nothing was delivered within 0 ms"
    end
  end

  test "the real run/1 on a host (stub .erl, no NIF) fails instead of raising" do
    leftovers = fn -> Path.wildcard(Path.join(Mob.data_dir(), "mob_vision_selftest_*")) end
    before = leftovers.()
    reason = assert_fail(SelfTest.run(%{platform: :ios, device: :simulator}))
    assert reason =~ "mob_vision_nif is not linked"
    assert leftovers.() == before
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == MobVision.SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end
end
