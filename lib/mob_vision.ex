defmodule MobVision do
  @moduledoc """
  On-device text recognition (OCR) — a Mob plugin.

  Recognizes text in a still image file (a photo you captured with `mob_camera`
  or picked with `mob_photos`, or any local image). Runs entirely on device —
  **no network, no camera session, and no runtime permission** (it reads a file
  the app already has).

  Call `recognize_text/3`; the result arrives at `handle_info`:

      handle_info({:vision, :text, text}, socket)      # text :: String.t()
      handle_info({:vision, :error, reason}, socket)   # reason :: String.t()

  - `text` — the full recognized text, blocks joined by `"\\n"` in reading order
    (`""` when the image contains no detectable text).
  - `reason` (on `:error`) — a short reason string, e.g. `"no_image"` when the
    path is missing/unreadable, or the platform recognizer's error message.

  Per-block bounding boxes (for highlighting/overlays) are a planned follow-up;
  v1 returns the recognized text.

  Built to grow: face and pose detection are planned on the same Vision / ML Kit
  seam under `MobVision`.

  iOS: the `Vision` framework (`VNRecognizeTextRequest`). Android: ML Kit
  `text-recognition` (`TextRecognition` + `InputImage.fromFilePath`).
  """

  @doc """
  Recognize text in the image at `path` (a local file: JPEG / PNG / HEIC).

  Returns the socket unchanged (fire-and-forget); the result is delivered
  asynchronously as `{:vision, :text, map}` or `{:vision, :error, reason}`.

  Options:
    - `languages: [String.t()]` — BCP-47 language hints (e.g. `["en", "fr"]`).
      Advisory: iOS uses them to prioritize scripts; ML Kit's default Latin
      recognizer ignores them. Omit to auto-detect Latin script.
  """
  @spec recognize_text(Mob.Socket.t(), Path.t(), keyword()) :: Mob.Socket.t()
  def recognize_text(socket, path, opts \\ []) when is_binary(path) do
    :mob_vision_nif.recognize_text(encode_request(path, opts))
    socket
  end

  @doc false
  # The JSON request the NIF expects — extracted so the option normalization is
  # unit-testable without a loaded NIF. Returns an iodata/binary JSON document
  # with the image path and the (stringified) language hints.
  @spec encode_request(Path.t(), keyword()) :: binary()
  def encode_request(path, opts) do
    langs = opts |> Keyword.get(:languages, []) |> Enum.map(&to_string/1)
    IO.iodata_to_binary(:json.encode(%{"path" => path, "languages" => langs}))
  end
end
