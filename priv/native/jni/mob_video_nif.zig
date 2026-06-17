//! mob_video_nif — Android video tier-1 ZIG plugin NIF.
//!
//! The Kotlin side is the plugin-owned bridge class
//! `io.mob.video.MobVideoBridge` (MediaExtractor + MediaMuxer stream-copy,
//! MediaMetadataRetriever for probe/thumbnail). Each NIF returns :ok and runs
//! async on the bridge's worker thread; results land via the exported deliver
//! thunks (info / clipped / thumbnail / audio / error).
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
//!
//! Bridge-class registration: the JVM calls
//! `Java_io_mob_video_MobVideoBridge_nativeRegister(jenv, cls)` at startup
//! (MobPluginBootstrap.registerAll -> register()); that thunk caches a global
//! ref to the bridge jclass + the 4 method IDs. All numeric bridge args are
//! `long` (JNI signature "...J...") so there is no int/long varargs mixing.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const VidMethods = struct {
    probe: jni.JMethodID = null,
    clip: jni.JMethodID = null,
    thumbnail: jni.JMethodID = null,
    extract_audio: jni.JMethodID = null,
};

var g_vid: VidMethods = .{};
var g_vid_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method ids ───────────
export fn Java_io_mob_video_MobVideoBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_vid_cls = jni.newGlobalRef(jenv, cls);
    if (g_vid_cls == null) return;
    g_vid.probe = jni.getStaticMethodID(jenv, cls, "video_probe", "(JLjava/lang/String;)V");
    g_vid.clip = jni.getStaticMethodID(jenv, cls, "video_clip", "(JLjava/lang/String;Ljava/lang/String;JJ)V");
    g_vid.thumbnail = jni.getStaticMethodID(jenv, cls, "video_thumbnail", "(JLjava/lang/String;Ljava/lang/String;JJ)V");
    g_vid.extract_audio = jni.getStaticMethodID(jenv, cls, "video_extract_audio", "(JLjava/lang/String;Ljava/lang/String;)V");
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core / camera) ─────
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

// Copy a binary/iolist arg into a null-terminated buffer. The bridge call
// (newStringUTF) copies the jstring synchronously, so a stack buffer is fine.
fn binArgZ(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM, buf: []u8) bool {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, term, &bin) == 0) return false;
    const n = @min(bin.size, buf.len - 1);
    @memcpy(buf[0..n], bin.data[0..n]);
    buf[n] = 0;
    return true;
}

// Build a `path` -> binary single-entry map term from a JNI string.
fn pathMap(jenv: *jni.JNIEnv, env: ?*erts.ErlNifEnv, path: jni.JString) ?erts.ERL_NIF_TERM {
    const path_c = jenv.*.GetStringUTFChars.?(jenv, path, null) orelse return null;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, path, path_c);
    const plen = std.mem.len(path_c);
    var pbin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(plen, &pbin) == 0) return null;
    @memcpy(pbin.data[0..plen], path_c[0..plen]);
    return erts.enif_make_binary(env, &pbin);
}

// ── Inbound delivery thunks — the bridge's worker calls these ─────────────

// {:video, :info, %{duration_ms, width, height, rotation, has_audio, bitrate, frame_rate}}
export fn Java_io_mob_video_MobVideoBridge_nativeDeliverVideoInfo(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    duration_ms: jni.JLong,
    width: c_int,
    height: c_int,
    rotation: c_int,
    has_audio: c_int,
    bitrate: jni.JLong,
    frame_rate: f64,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const keys = [_]erts.ERL_NIF_TERM{
        erts.atom(env, "duration_ms"),
        erts.atom(env, "width"),
        erts.atom(env, "height"),
        erts.atom(env, "rotation"),
        erts.atom(env, "has_audio"),
        erts.atom(env, "bitrate"),
        erts.atom(env, "frame_rate"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_int64(env, duration_ms),
        erts.enif_make_int(env, width),
        erts.enif_make_int(env, height),
        erts.enif_make_int(env, rotation),
        if (has_audio != 0) erts.atom(env, "true") else erts.atom(env, "false"),
        erts.enif_make_int64(env, bitrate),
        erts.enif_make_double(env, frame_rate),
    };
    const map = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "video"), erts.atom(env, "info"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

// {:video, :clipped, %{path, duration_ms}}
export fn Java_io_mob_video_MobVideoBridge_nativeDeliverClipped(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    path: jni.JString,
    duration_ms: jni.JLong,
) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const pterm = pathMap(jenv, env, path) orelse return;
    const keys = [_]erts.ERL_NIF_TERM{ erts.atom(env, "path"), erts.atom(env, "duration_ms") };
    const vals = [_]erts.ERL_NIF_TERM{ pterm, erts.enif_make_int64(env, duration_ms) };
    const map = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "video"), erts.atom(env, "clipped"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

// {:video, :thumbnail, %{path, width, height}}
export fn Java_io_mob_video_MobVideoBridge_nativeDeliverThumbnail(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    path: jni.JString,
    width: c_int,
    height: c_int,
) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const pterm = pathMap(jenv, env, path) orelse return;
    const keys = [_]erts.ERL_NIF_TERM{ erts.atom(env, "path"), erts.atom(env, "width"), erts.atom(env, "height") };
    const vals = [_]erts.ERL_NIF_TERM{ pterm, erts.enif_make_int(env, width), erts.enif_make_int(env, height) };
    const map = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "video"), erts.atom(env, "thumbnail"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

// {:video, :audio_extracted, %{path}}
export fn Java_io_mob_video_MobVideoBridge_nativeDeliverAudio(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    path: jni.JString,
) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const pterm = pathMap(jenv, env, path) orelse return;
    const keys = [_]erts.ERL_NIF_TERM{erts.atom(env, "path")};
    const vals = [_]erts.ERL_NIF_TERM{pterm};
    const map = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "video"), erts.atom(env, "audio_extracted"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

// {:video, :error, reason}. code: 0 not_found, 1 unsupported, 2 io_error, 3 bad_range.
export fn Java_io_mob_video_MobVideoBridge_nativeDeliverVideoError(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    code: c_int,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const reason = switch (code) {
        0 => erts.atom(env, "not_found"),
        1 => erts.atom(env, "unsupported"),
        3 => erts.atom(env, "bad_range"),
        else => erts.atom(env, "io_error"),
    };
    const msg = erts.makeTuple(env, .{ erts.atom(env, "video"), erts.atom(env, "error"), reason });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Bridge-call helpers (build jstrings, call static void, clean up) ───────
fn callProbe(env: ?*erts.ErlNifEnv, pid: erts.ErlNifPid, src: [*:0]const u8) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jsrc = jni.newStringUTF(jenv, src);
    jenv.*.CallStaticVoidMethod.?(jenv, g_vid_cls, g_vid.probe, pidToJlong(pid), jsrc);
    if (jsrc != null) jni.deleteLocalRef(jenv, jsrc);
    detachIfAttached(attached);
    return erts.ok(env);
}

fn callTwoPathTwoLong(
    env: ?*erts.ErlNifEnv,
    method: jni.JMethodID,
    pid: erts.ErlNifPid,
    src: [*:0]const u8,
    dst: [*:0]const u8,
    a: jni.JLong,
    b: jni.JLong,
) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jsrc = jni.newStringUTF(jenv, src);
    const jdst = jni.newStringUTF(jenv, dst);
    jenv.*.CallStaticVoidMethod.?(jenv, g_vid_cls, method, pidToJlong(pid), jsrc, jdst, a, b);
    if (jsrc != null) jni.deleteLocalRef(jenv, jsrc);
    if (jdst != null) jni.deleteLocalRef(jenv, jdst);
    detachIfAttached(attached);
    return erts.ok(env);
}

fn callTwoPath(
    env: ?*erts.ErlNifEnv,
    method: jni.JMethodID,
    pid: erts.ErlNifPid,
    src: [*:0]const u8,
    dst: [*:0]const u8,
) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jsrc = jni.newStringUTF(jenv, src);
    const jdst = jni.newStringUTF(jenv, dst);
    jenv.*.CallStaticVoidMethod.?(jenv, g_vid_cls, method, pidToJlong(pid), jsrc, jdst);
    if (jsrc != null) jni.deleteLocalRef(jenv, jsrc);
    if (jdst != null) jni.deleteLocalRef(jenv, jdst);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── NIFs ──────────────────────────────────────────────────────────────────
fn nif_video_probe(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var src: [2048]u8 = undefined;
    if (!binArgZ(env, argv[0], &src)) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callProbe(env, pid, @ptrCast(&src));
}

fn nif_video_clip(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var src: [2048]u8 = undefined;
    var dst: [2048]u8 = undefined;
    if (!binArgZ(env, argv[0], &src) or !binArgZ(env, argv[1], &dst)) return erts.badarg(env);
    // ms timestamps fit comfortably in 32 bits (~24 days); widen to JLong for
    // the bridge's "...JJ" signature (the binding only exposes enif_get_int).
    var start_ms: c_int = 0;
    var end_ms: c_int = 0;
    _ = erts.enif_get_int(env, argv[2], &start_ms);
    _ = erts.enif_get_int(env, argv[3], &end_ms);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callTwoPathTwoLong(env, g_vid.clip, pid, @ptrCast(&src), @ptrCast(&dst), @intCast(start_ms), @intCast(end_ms));
}

fn nif_video_thumbnail(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var src: [2048]u8 = undefined;
    var dst: [2048]u8 = undefined;
    if (!binArgZ(env, argv[0], &src) or !binArgZ(env, argv[1], &dst)) return erts.badarg(env);
    var at_ms: c_int = 0;
    var max_width: c_int = 0;
    _ = erts.enif_get_int(env, argv[2], &at_ms);
    _ = erts.enif_get_int(env, argv[3], &max_width);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callTwoPathTwoLong(env, g_vid.thumbnail, pid, @ptrCast(&src), @ptrCast(&dst), @intCast(at_ms), @intCast(max_width));
}

fn nif_video_extract_audio(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var src: [2048]u8 = undefined;
    var dst: [2048]u8 = undefined;
    if (!binArgZ(env, argv[0], &src) or !binArgZ(env, argv[1], &dst)) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callTwoPath(env, g_vid.extract_audio, pid, @ptrCast(&src), @ptrCast(&dst));
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "video_probe", .arity = 1, .fptr = nif_video_probe, .flags = 0 },
    .{ .name = "video_clip", .arity = 4, .fptr = nif_video_clip, .flags = 0 },
    .{ .name = "video_thumbnail", .arity = 4, .fptr = nif_video_thumbnail, .flags = 0 },
    .{ .name = "video_extract_audio", .arity = 2, .fptr = nif_video_extract_audio, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_video_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_video_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
