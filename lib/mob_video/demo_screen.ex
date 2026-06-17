defmodule MobVideo.DemoScreen do
  @moduledoc """
  A ready-to-run sample screen exercising `MobVideo`, shipped so a generated app
  can kick the tires the moment the plugin is activated. Declared in the plugin
  manifest's `:screens`, so the host's home can surface it by route without
  writing any code. Delete it (and the manifest entry) in a real app.

  It operates on a `sample.mp4` you drop into the app's documents directory
  (`Mob.Storage.dir(:documents)`); with no file present the buttons still
  demonstrate the message flow by delivering `{:video, :error, :not_found}`.
  """
  use Mob.Screen

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket, status: "Drop a sample.mp4 in Documents, then tap.", result: nil)}
  end

  @impl true
  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="Video" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text={assigns.status} text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={8} />
        <Text text={result_text(assigns)} text_size={:md} text_color={:on_surface} padding={4} />
        <Spacer size={16} />
        <Button text="Probe" background={:primary} text_color={:on_primary} padding={:space_md} fill_width={true} on_tap={{self(), :probe}} />
        <Spacer size={12} />
        <Button text="Clip first 3s" background={:surface} text_color={:on_surface} padding={:space_md} fill_width={true} on_tap={{self(), :clip}} />
        <Spacer size={12} />
        <Button text="Thumbnail @1s" background={:surface} text_color={:on_surface} padding={:space_md} fill_width={true} on_tap={{self(), :thumb}} />
        <Spacer size={12} />
        <Button text="Extract audio" background={:surface} text_color={:on_surface} padding={:space_md} fill_width={true} on_tap={{self(), :audio}} />
      </Column>
    </Scroll>
    """
  end

  defp result_text(%{result: nil}), do: "No result yet"
  defp result_text(%{result: r}), do: inspect(r, pretty: true)

  defp src, do: Path.join(Mob.Storage.dir(:documents), "sample.mp4")
  defp out(name), do: Path.join(Mob.Storage.dir(:cache), name)

  @impl true
  def handle_info({:tap, :probe}, socket) do
    {:noreply, MobVideo.probe(socket, src()) |> working("Probing…")}
  end

  def handle_info({:tap, :clip}, socket) do
    {:noreply,
     MobVideo.clip(socket, src(), out("clip.mp4"), end_ms: 3000) |> working("Clipping…")}
  end

  def handle_info({:tap, :thumb}, socket) do
    {:noreply,
     MobVideo.thumbnail(socket, src(), out("thumb.jpg"), at_ms: 1000)
     |> working("Grabbing frame…")}
  end

  def handle_info({:tap, :audio}, socket) do
    {:noreply,
     MobVideo.extract_audio(socket, src(), out("audio.m4a")) |> working("Extracting audio…")}
  end

  def handle_info({:video, kind, payload}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Done: #{kind}", result: {kind, payload})}
  end

  defp working(socket, status), do: Mob.Socket.assign(socket, status: status, result: nil)
end
