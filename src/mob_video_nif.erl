%% mob_video_nif — Erlang NIF module for the video tier-1 plugin.
%%
%% iOS: priv/native/ios/mob_video_nif.m (Objective-C, AVFoundation).
%% Android: priv/native/jni/mob_video_nif.zig (MediaExtractor/MediaMuxer/
%% MediaMetadataRetriever via the io.mob.video.MobVideoBridge Kotlin bridge).
%% Both register this module via ERL_NIF_INIT and are statically linked into the
%% host binary on device. On a host dev build neither is linked, so on_load
%% tolerates the failure and the NIFs fall back to nif_error until the native
%% merge links one.
%%
%% Every NIF returns :ok immediately and is asynchronous — the result lands in
%% the caller's mailbox as a {video, _} message (see the MobVideo moduledoc).
-module(mob_video_nif).
-export([video_probe/1, video_clip/4, video_thumbnail/4, video_extract_audio/2]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_video_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

video_probe(_Src) ->
    erlang:nif_error(nif_not_loaded).

video_clip(_Src, _Dst, _StartMs, _EndMs) ->
    erlang:nif_error(nif_not_loaded).

video_thumbnail(_Src, _Dst, _AtMs, _MaxWidth) ->
    erlang:nif_error(nif_not_loaded).

video_extract_audio(_Src, _Dst) ->
    erlang:nif_error(nif_not_loaded).
