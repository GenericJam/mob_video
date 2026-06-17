defmodule MobVideo do
  @moduledoc """
  On-device video processing — a Mob plugin backed entirely by the platform
  video toolkits (Android `MediaExtractor`/`MediaMuxer`/`MediaMetadataRetriever`,
  iOS `AVFoundation`). No ffmpeg: the operations here are the ones the OS does
  natively, losslessly, and hardware-accelerated.

  Every call is **asynchronous** — the work runs on a background thread and the
  result arrives in the screen's `handle_info/2`. Pass a writable destination
  path under the app's own storage (e.g. `Mob.Storage.dir(:cache)`); `src` is a
  local file path (copy a picked/downloaded file into app storage first).

  ## Operations

    * `probe/2` — read a clip's metadata (no output file).
    * `clip/4` — cut a time range, **stream-copy** (no re-encode, lossless, fast).
    * `thumbnail/4` — extract a single frame as a JPEG.
    * `extract_audio/3` — pull the audio track into its own file.

  ## Result messages

      handle_info({:video, :info, %{duration_ms:, width:, height:, rotation:,
                                    has_audio:, bitrate:, frame_rate:}}, socket)
      handle_info({:video, :clipped, %{path:, duration_ms:}}, socket)
      handle_info({:video, :thumbnail, %{path:, width:, height:}}, socket)
      handle_info({:video, :audio_extracted, %{path:}}, socket)
      handle_info({:video, :error, reason}, socket)

  Common `reason` atoms: `:not_found` (src missing/unreadable), `:unsupported`
  (no video/audio track, or a container the OS can't demux), `:io_error` (the
  write failed), `:bad_range` (clip start/end outside the clip).

  ## Permissions

  Processing a file the app can already read needs **no** runtime permission.
  Reading from the shared media store (a path under the system gallery) needs
  `READ_MEDIA_VIDEO` (Android 13+) / Photos access (iOS) — request `:photos` via
  `Mob.Permissions` and pick through `MobPhotos` first, then hand the resulting
  local path here.

  ## Not (yet) here

  Re-encoding/transcoding, filters, overlays and concat-across-codecs are
  deliberately out of scope: they need a software codec pipeline (ffmpeg) with
  real size/licensing/perf cost. Everything above is stream-copy or single-frame
  decode, which the platform does for free. See the README for the rationale.
  """

  @doc """
  Read `src`'s metadata. Delivers `{:video, :info, map}` or `{:video, :error,
  reason}`.

  The map carries `:duration_ms`, `:width`, `:height` (pixels, pre-rotation),
  `:rotation` (degrees, 0/90/180/270), `:has_audio` (boolean), `:bitrate`
  (bits/sec, 0 if unknown) and `:frame_rate` (fps, 0.0 if unknown).
  """
  @spec probe(Mob.Socket.t(), String.t()) :: Mob.Socket.t()
  def probe(socket, src) when is_binary(src) do
    :mob_video_nif.video_probe(src)
    socket
  end

  @doc """
  Cut `src` to the `[start_ms, end_ms)` range, writing to `dst` by **stream copy**
  (no re-encode — lossless and near-instant). Delivers `{:video, :clipped,
  %{path:, duration_ms:}}` or `{:video, :error, reason}`.

  Options:
    * `:start_ms` — range start (default `0`).
    * `:end_ms` — range end (default the clip's duration).
  """
  @spec clip(Mob.Socket.t(), String.t(), String.t(), keyword()) :: Mob.Socket.t()
  def clip(socket, src, dst, opts \\ []) when is_binary(src) and is_binary(dst) do
    start_ms = Keyword.get(opts, :start_ms, 0)
    end_ms = Keyword.get(opts, :end_ms, 0)
    :mob_video_nif.video_clip(src, dst, start_ms, end_ms)
    socket
  end

  @doc """
  Extract a single frame from `src` at `:at_ms` (default `0`) as a JPEG at `dst`.
  Delivers `{:video, :thumbnail, %{path:, width:, height:}}` or `{:video,
  :error, reason}`.

  Options:
    * `:at_ms` — frame timestamp (default `0`).
    * `:max_width` — scale so the longer side is at most this many pixels
      (default `0` = full resolution).
  """
  @spec thumbnail(Mob.Socket.t(), String.t(), String.t(), keyword()) :: Mob.Socket.t()
  def thumbnail(socket, src, dst, opts \\ []) when is_binary(src) and is_binary(dst) do
    at_ms = Keyword.get(opts, :at_ms, 0)
    max_width = Keyword.get(opts, :max_width, 0)
    :mob_video_nif.video_thumbnail(src, dst, at_ms, max_width)
    socket
  end

  @doc """
  Pull `src`'s audio track into `dst` by stream copy. Delivers `{:video,
  :audio_extracted, %{path:}}` or `{:video, :error, reason}` (`:unsupported`
  when the clip has no audio track).
  """
  @spec extract_audio(Mob.Socket.t(), String.t(), String.t()) :: Mob.Socket.t()
  def extract_audio(socket, src, dst) when is_binary(src) and is_binary(dst) do
    :mob_video_nif.video_extract_audio(src, dst)
    socket
  end
end
