/* mob_video_nif — iOS video tier-1 plugin NIF (Objective-C, AVFoundation).
 *
 * The mirror of the Android MediaExtractor/MediaMuxer bridge: probe via
 * AVURLAsset, clip via AVAssetExportSession passthrough (stream-copy, no
 * re-encode), thumbnail via AVAssetImageGenerator, extract-audio via a
 * single-track AVMutableComposition exported to .m4a. Every NIF returns :ok and
 * runs async on a background queue; results are delivered by pid with raw
 * enif_send, building the SAME message terms as the Android side.
 *
 * Compiled as ObjC (-fobjc-arc) by the plugin C-NIF path because the manifest
 * entry is lang: :objc. Registered as the Erlang module mob_video_nif via
 * ERL_NIF_INIT.
 */
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <erl_nif.h>

/* Error codes shared with the Android bridge: 0 not_found, 1 unsupported,
 * 2 io_error, 3 bad_range. */
enum { ERR_NOT_FOUND = 0, ERR_UNSUPPORTED = 1, ERR_IO = 2, ERR_BAD_RANGE = 3 };

// ── Delivery helpers (raw enif_send, mirroring the Android term shapes) ────
static ERL_NIF_TERM bin_term(ErlNifEnv *env, const char *s) {
  size_t n = strlen(s);
  ERL_NIF_TERM t;
  unsigned char *buf = enif_make_new_binary(env, n, &t);
  memcpy(buf, s, n);
  return t;
}

static void send_error(ErlNifPid pid, int code) {
  ErlNifEnv *e = enif_alloc_env();
  const char *reason = code == ERR_NOT_FOUND     ? "not_found"
                       : code == ERR_UNSUPPORTED ? "unsupported"
                       : code == ERR_BAD_RANGE   ? "bad_range"
                                                 : "io_error";
  ERL_NIF_TERM msg =
      enif_make_tuple3(e, enif_make_atom(e, "video"),
                       enif_make_atom(e, "error"), enif_make_atom(e, reason));
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

static void send_info(ErlNifPid pid, long long duration_ms, int width,
                      int height, int rotation, int has_audio,
                      long long bitrate, double frame_rate) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM keys[7] = {
      enif_make_atom(e, "duration_ms"), enif_make_atom(e, "width"),
      enif_make_atom(e, "height"),      enif_make_atom(e, "rotation"),
      enif_make_atom(e, "has_audio"),   enif_make_atom(e, "bitrate"),
      enif_make_atom(e, "frame_rate")};
  ERL_NIF_TERM vals[7] = {enif_make_int64(e, duration_ms),
                          enif_make_int(e, width),
                          enif_make_int(e, height),
                          enif_make_int(e, rotation),
                          enif_make_atom(e, has_audio ? "true" : "false"),
                          enif_make_int64(e, bitrate),
                          enif_make_double(e, frame_rate)};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, keys, vals, 7, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "video"),
                                      enif_make_atom(e, "info"), map);
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

static void send_clipped(ErlNifPid pid, const char *path,
                         long long duration_ms) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM keys[2] = {enif_make_atom(e, "path"),
                          enif_make_atom(e, "duration_ms")};
  ERL_NIF_TERM vals[2] = {bin_term(e, path), enif_make_int64(e, duration_ms)};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, keys, vals, 2, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "video"),
                                      enif_make_atom(e, "clipped"), map);
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

static void send_thumbnail(ErlNifPid pid, const char *path, int width,
                           int height) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM keys[3] = {enif_make_atom(e, "path"), enif_make_atom(e, "width"),
                          enif_make_atom(e, "height")};
  ERL_NIF_TERM vals[3] = {bin_term(e, path), enif_make_int(e, width),
                          enif_make_int(e, height)};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, keys, vals, 3, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "video"),
                                      enif_make_atom(e, "thumbnail"), map);
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

static void send_audio(ErlNifPid pid, const char *path) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM keys[1] = {enif_make_atom(e, "path")};
  ERL_NIF_TERM vals[1] = {bin_term(e, path)};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, keys, vals, 1, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(
      e, enif_make_atom(e, "video"), enif_make_atom(e, "audio_extracted"), map);
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

// ── Shared utilities ───────────────────────────────────────────────────────
static NSString *arg_to_nsstring(ErlNifEnv *env, ERL_NIF_TERM term) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin) &&
      !enif_inspect_iolist_as_binary(env, term, &bin)) {
    return nil;
  }
  return [[NSString alloc] initWithBytes:bin.data
                                  length:bin.size
                                encoding:NSUTF8StringEncoding];
}

static int rotation_degrees(AVAssetTrack *track) {
  CGAffineTransform t = track.preferredTransform;
  double angle = atan2(t.b, t.a) * 180.0 / M_PI;
  int deg = ((int)lround(angle) % 360 + 360) % 360;
  return deg;
}

// ── Probe ──────────────────────────────────────────────────────────────────
static void do_probe(ErlNifPid pid, NSString *src) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:src]) {
    send_error(pid, ERR_NOT_FOUND);
    return;
  }
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src]
                                          options:nil];
  AVAssetTrack *video =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (!video) {
    send_error(pid, ERR_UNSUPPORTED);
    return;
  }
  AVAssetTrack *audio =
      [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  CGSize size = video.naturalSize;
  long long duration_ms =
      (long long)(CMTimeGetSeconds(asset.duration) * 1000.0);
  long long bitrate = (long long)llround(video.estimatedDataRate +
                                         (audio ? audio.estimatedDataRate : 0));
  send_info(pid, duration_ms, (int)llround(size.width),
            (int)llround(size.height), rotation_degrees(video), audio != nil,
            bitrate, video.nominalFrameRate);
}

// ── Clip (passthrough export over a time range) ────────────────────────────
static void do_clip(ErlNifPid pid, NSString *src, NSString *dst,
                    long long start_ms, long long end_ms) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:src]) {
    send_error(pid, ERR_NOT_FOUND);
    return;
  }
  if (end_ms > 0 && end_ms <= start_ms) {
    send_error(pid, ERR_BAD_RANGE);
    return;
  }
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src]
                                          options:nil];
  AVAssetExportSession *export = [[AVAssetExportSession alloc]
      initWithAsset:asset
         presetName:AVAssetExportPresetPassthrough];
  if (!export) {
    send_error(pid, ERR_UNSUPPORTED);
    return;
  }
  [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
  CMTime start = CMTimeMake(start_ms, 1000);
  CMTime duration = end_ms > 0 ? CMTimeMake(end_ms - start_ms, 1000)
                               : CMTimeSubtract(asset.duration, start);
  export.timeRange = CMTimeRangeMake(start, duration);
  export.outputURL = [NSURL fileURLWithPath:dst];
  export.outputFileType = AVFileTypeMPEG4;
  const char *dst_c = dst.UTF8String;
  long long out_ms = (long long)(CMTimeGetSeconds(duration) * 1000.0);
  [export exportAsynchronouslyWithCompletionHandler:^{
    if (export.status == AVAssetExportSessionStatusCompleted) {
      send_clipped(pid, dst_c, out_ms);
    } else {
      send_error(pid, ERR_IO);
    }
  }];
}

// ── Extract audio (single-track composition -> .m4a passthrough) ───────────
static void do_extract_audio(ErlNifPid pid, NSString *src, NSString *dst) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:src]) {
    send_error(pid, ERR_NOT_FOUND);
    return;
  }
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src]
                                          options:nil];
  AVAssetTrack *audio =
      [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  if (!audio) {
    send_error(pid, ERR_UNSUPPORTED);
    return;
  }
  AVMutableComposition *comp = [AVMutableComposition composition];
  AVMutableCompositionTrack *track =
      [comp addMutableTrackWithMediaType:AVMediaTypeAudio
                        preferredTrackID:kCMPersistentTrackID_Invalid];
  NSError *err = nil;
  [track insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration)
                 ofTrack:audio
                  atTime:kCMTimeZero
                   error:&err];
  if (err) {
    send_error(pid, ERR_IO);
    return;
  }
  AVAssetExportSession *export = [[AVAssetExportSession alloc]
      initWithAsset:comp
         presetName:AVAssetExportPresetPassthrough];
  [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
  export.outputURL = [NSURL fileURLWithPath:dst];
  export.outputFileType = AVFileTypeAppleM4A;
  const char *dst_c = dst.UTF8String;
  [export exportAsynchronouslyWithCompletionHandler:^{
    if (export.status == AVAssetExportSessionStatusCompleted) {
      send_audio(pid, dst_c);
    } else {
      send_error(pid, ERR_IO);
    }
  }];
}

// ── Thumbnail (one decoded frame -> JPEG) ──────────────────────────────────
static void do_thumbnail(ErlNifPid pid, NSString *src, NSString *dst,
                         long long at_ms, long long max_width) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:src]) {
    send_error(pid, ERR_NOT_FOUND);
    return;
  }
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src]
                                          options:nil];
  if ([asset tracksWithMediaType:AVMediaTypeVideo].count == 0) {
    send_error(pid, ERR_UNSUPPORTED);
    return;
  }
  AVAssetImageGenerator *gen =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  gen.appliesPreferredTrackTransform = YES;
  gen.requestedTimeToleranceBefore = kCMTimePositiveInfinity;
  gen.requestedTimeToleranceAfter = kCMTimePositiveInfinity;
  if (max_width > 0)
    gen.maximumSize = CGSizeMake(max_width, max_width);
  NSError *err = nil;
  CGImageRef img = [gen copyCGImageAtTime:CMTimeMake(at_ms, 1000)
                               actualTime:NULL
                                    error:&err];
  if (!img) {
    send_error(pid, ERR_UNSUPPORTED);
    return;
  }
  int w = (int)CGImageGetWidth(img);
  int h = (int)CGImageGetHeight(img);
  NSURL *url = [NSURL fileURLWithPath:dst];
  CGImageDestinationRef sink = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, (CFStringRef) @"public.jpeg", 1, NULL);
  if (!sink) {
    CGImageRelease(img);
    send_error(pid, ERR_IO);
    return;
  }
  NSDictionary *props =
      @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.9};
  CGImageDestinationAddImage(sink, img, (__bridge CFDictionaryRef)props);
  bool ok = CGImageDestinationFinalize(sink);
  CFRelease(sink);
  CGImageRelease(img);
  if (ok) {
    send_thumbnail(pid, dst.UTF8String, w, h);
  } else {
    send_error(pid, ERR_IO);
  }
}

// ── NIFs ────────────────────────────────────────────────────────────────────
static dispatch_queue_t video_queue(void) {
  static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    q = dispatch_queue_create("io.mob.video.work", DISPATCH_QUEUE_SERIAL);
  });
  return q;
}

static ERL_NIF_TERM nif_video_probe(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  NSString *src = arg_to_nsstring(env, argv[0]);
  ErlNifPid pid;
  enif_self(env, &pid);
  if (!src)
    return enif_make_badarg(env);
  dispatch_async(video_queue(), ^{
    do_probe(pid, src);
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_video_clip(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  NSString *src = arg_to_nsstring(env, argv[0]);
  NSString *dst = arg_to_nsstring(env, argv[1]);
  int start_ms = 0, end_ms = 0;
  enif_get_int(env, argv[2], &start_ms);
  enif_get_int(env, argv[3], &end_ms);
  ErlNifPid pid;
  enif_self(env, &pid);
  if (!src || !dst)
    return enif_make_badarg(env);
  dispatch_async(video_queue(), ^{
    do_clip(pid, src, dst, start_ms, end_ms);
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_video_thumbnail(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
  (void)argc;
  NSString *src = arg_to_nsstring(env, argv[0]);
  NSString *dst = arg_to_nsstring(env, argv[1]);
  int at_ms = 0, max_width = 0;
  enif_get_int(env, argv[2], &at_ms);
  enif_get_int(env, argv[3], &max_width);
  ErlNifPid pid;
  enif_self(env, &pid);
  if (!src || !dst)
    return enif_make_badarg(env);
  dispatch_async(video_queue(), ^{
    do_thumbnail(pid, src, dst, at_ms, max_width);
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_video_extract_audio(ErlNifEnv *env, int argc,
                                            const ERL_NIF_TERM argv[]) {
  (void)argc;
  NSString *src = arg_to_nsstring(env, argv[0]);
  NSString *dst = arg_to_nsstring(env, argv[1]);
  ErlNifPid pid;
  enif_self(env, &pid);
  if (!src || !dst)
    return enif_make_badarg(env);
  dispatch_async(video_queue(), ^{
    do_extract_audio(pid, src, dst);
  });
  return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"video_probe", 1, nif_video_probe, 0},
    {"video_clip", 4, nif_video_clip, 0},
    {"video_thumbnail", 4, nif_video_thumbnail, 0},
    {"video_extract_audio", 2, nif_video_extract_audio, 0},
};

ERL_NIF_INIT(mob_video_nif, nif_funcs, NULL, NULL, NULL, NULL)
