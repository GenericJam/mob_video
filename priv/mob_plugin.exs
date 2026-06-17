%{
  name: :mob_video,
  mob_version: "~> 0.7",
  plugin_spec_version: 1,
  description: "On-device video processing (clip/probe/thumbnail/extract-audio) via the platform toolkits",
  # A sample screen the host can navigate to by route. Pure-Elixir +
  # hot-pushable; drop it and this entry in a real app that builds its own UI.
  screens: [
    %{module: MobVideo.DemoScreen, default_route: "/mob_video/demo"}
  ],
  nifs: [
    # iOS: Objective-C NIF driving AVFoundation. lang: :objc -> compiled as ObjC
    # (.m) with -fobjc-arc; platform: :ios so it isn't pulled into the Android
    # build.
    %{module: :mob_video_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to MediaExtractor/MediaMuxer/MediaMetadataRetriever
    # via the Kotlin MobVideoBridge. platform: :android so the iOS build skips it.
    %{module: :mob_video_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  # No runtime permission *capability* is registered: processing a file the app
  # can already read needs none. Obtaining a gallery path is mob_photos' job
  # (request :photos there); this plugin only consumes a local path.
  permissions: [],
  android: %{
    bridge_kt: "priv/native/android/MobVideoBridge.kt",
    bridge_class: "io.mob.video.MobVideoBridge",
    # Manifest-merged so a screen handed a shared-store gallery path can read it
    # (Android 13+). All the codecs/muxers are framework — no gradle deps.
    permissions: ["android.permission.READ_MEDIA_VIDEO"]
  },
  ios: %{
    frameworks: ["AVFoundation", "CoreMedia", "CoreGraphics", "ImageIO", "MobileCoreServices"]
  }
}
