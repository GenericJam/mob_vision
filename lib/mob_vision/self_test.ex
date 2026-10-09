defmodule MobVision.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One real recognition, no UI, no camera, no permission: the test renders the
  word `LEFT` in large block letters into a PNG under `Mob.data_dir/0`, calls
  `recognize_text/1` on it, waits for the native delivery and deletes the file.

    * `{:vision, :text, text}` where `text` reads `LEFT` (case and whitespace
      ignored) passes. That answer only comes from the recognizer's success
      path: on iOS the NIF loaded the file into a `CGImage` and
      `VNRecognizeTextRequest` (Vision, accurate level) ran on it on a
      background queue; on Android the zig NIF called
      `MobVisionBridge.recognize_text` through JNI (so `nativeRegister` ran
      and the bootstrap handed the bridge an Activity), `InputImage.fromFilePath`
      decoded the file and ML Kit's bundled Latin recognizer read it. Both
      recognizers run fully on device and offline (Vision ships with iOS, the
      ML Kit model is in the `text-recognition` artifact, not a Play services
      download), so an iOS simulator and an Android emulator are expected to
      pass like a phone.
    * Any other text, including `""`, is a failure: the pipeline ran but did
      not read a clean, high-contrast word.
    * `{:vision, :error, reason}` is a failure: `"no_activity"` (Android: the
      bootstrap never called `setActivity`), `"no_image"` (the native side
      could not open the file the test just wrote) or the recognizer's own
      error message.
    * `{:error, :bridge_not_registered}` from the NIF (Android: the bootstrap
      never called `MobVisionBridge.register()`, or the method-ID lookup
      failed) is a failure; so is no answer within 15 s.
    * The host stub's `nif_not_loaded` is a failure naming the NIF.

  There is no skip: the plugin needs no hardware, no permission and no
  network, so every device can give the full answer.
  """
  @behaviour Mob.Plugin.SelfTest

  @word "LEFT"
  @answer_timeout 15_000

  # 5x7 block glyphs for @word: straight strokes only, no diagonals a pixel
  # font renders as stairs, and no digit look-alikes (O/0, I/1, S/5, B/8).
  # macOS Vision and Tesseract both read the rendered image as "LEFT"
  # (Tesseract reads the same font's "TEXT" as "TEST").
  @glyphs %{
    ?L => ~w(#.... #.... #.... #.... #.... #.... #####),
    ?E => ~w(##### #.... #.... ####. #.... #.... #####),
    ?F => ~w(##### #.... #.... ####. #.... #.... #....),
    ?T => ~w(##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..)
  }
  @scale 16
  @margin 3

  @impl true
  def run(ctx), do: run(ctx, :mob_vision_nif)

  @doc false
  # `nif` is the NIF module (a stub in unit tests). Options: `:dir` where the
  # image is written (default `Mob.data_dir/0`), `:timeout` in ms.
  @spec run(Mob.Plugin.SelfTest.ctx(), module(), keyword()) :: Mob.Plugin.SelfTest.result()
  def run(%{platform: platform}, nif, opts \\ []) do
    dir = Keyword.get_lazy(opts, :dir, &Mob.data_dir/0)
    path = Path.join(dir, "mob_vision_selftest_#{System.unique_integer([:positive])}.png")
    File.write!(path, image())

    try do
      recognize(nif, path, platform, Keyword.get(opts, :timeout, @answer_timeout))
    after
      File.rm(path)
    end
  end

  defp recognize(nif, path, platform, timeout) do
    case nif.recognize_text(MobVision.encode_request(path, [])) do
      :ok ->
        await_answer(timeout, platform)

      {:error, :bridge_not_registered} ->
        {:fail,
         "recognize_text/1 returned {:error, :bridge_not_registered}: the Kotlin " <>
           "MobVisionBridge was never registered (nativeRegister did not run or the " <>
           "method-ID lookup failed)"}

      other ->
        {:fail, "recognize_text/1 on #{platform} returned #{inspect(other)}, expected :ok"}
    end
  rescue
    e in ErlangError ->
      {:fail,
       "mob_vision_nif is not linked into this build: recognize_text/1 raised " <>
         Exception.message(e)}
  end

  @doc false
  # Classifies what the native side delivers after recognize_text/1.
  @spec await_answer(non_neg_integer(), :ios | :android) :: Mob.Plugin.SelfTest.result()
  def await_answer(timeout, platform) do
    receive do
      {:vision, :text, text} when is_binary(text) ->
        if normalize(text) =~ @word do
          :pass
        else
          {:fail,
           "recognize_text/1 on #{platform} read #{inspect(text)} from an image of " <>
             "the word #{@word}, expected it to contain #{@word}"}
        end

      {:vision, :error, "no_activity"} ->
        {:fail,
         "recognize_text/1 delivered error \"no_activity\": MobVisionBridge has no " <>
           "Activity (MobActivityAware.setActivity was never called)"}

      {:vision, :error, "no_image"} ->
        {:fail,
         "recognize_text/1 on #{platform} delivered error \"no_image\" for the PNG the " <>
           "self-test had just written, expected the recognized text"}

      {:vision, :error, reason} ->
        {:fail,
         "recognize_text/1 on #{platform} delivered error #{inspect(reason)}, " <>
           "expected the recognized text #{@word}"}
    after
      timeout ->
        {:fail,
         "recognize_text/1 on #{platform} returned :ok but nothing was delivered " <>
           "within #{timeout} ms, expected {:vision, :text, _}"}
    end
  end

  defp normalize(text), do: text |> String.upcase() |> String.replace(~r/\s+/u, "")

  @doc false
  # The PNG the test recognizes: @word in black block letters on white,
  # 8-bit RGB, built here so nothing has to ship in priv/.
  @spec image() :: binary()
  def image do
    rows =
      for y <- 0..6 do
        @word
        |> String.to_charlist()
        |> Enum.map(&Enum.at(@glyphs[&1], y))
        |> Enum.join(".")
      end

    width = (String.length(hd(rows)) + 2 * @margin) * @scale
    blank = List.duplicate(String.duplicate(".", div(width, @scale)), @margin)
    pad = String.duplicate(".", @margin)
    cells = blank ++ Enum.map(rows, &(pad <> &1 <> pad)) ++ blank

    raw =
      for row <- cells, _ <- 1..@scale, into: <<>> do
        line = for <<c <- row>>, _ <- 1..@scale, into: <<>>, do: pixel(c)
        <<0, line::binary>>
      end

    height = length(cells) * @scale

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(raw)) <>
      chunk("IEND", <<>>)
  end

  defp pixel(?#), do: <<0, 0, 0>>
  defp pixel(_), do: <<255, 255, 255>>

  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end
end
