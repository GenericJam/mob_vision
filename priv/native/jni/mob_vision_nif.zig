//! mob_vision_nif — Android on-device OCR tier-1 ZIG plugin NIF.
//!
//! Bridges to the plugin-owned Kotlin class `io.mob.vision.MobVisionBridge`,
//! which runs ML Kit `text-recognition` on an image file
//! (`InputImage.fromFilePath`) off the main thread and feeds the result back
//! through the exported deliver thunks. No camera, no activity, no permission.
//!
//! Delivered message shapes:
//!   * text  -> {:vision, :text,  binary}   (the full recognized text; "" if none)
//!   * error -> {:vision, :error, binary}   (reason string, e.g. "no_image")
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const VisionMethods = struct {
    recognize_text: jni.JMethodID = null,
};

var g_vision: VisionMethods = .{};
var g_vision_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method id ────────────
export fn Java_io_mob_vision_MobVisionBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_vision_cls = jni.newGlobalRef(jenv, cls);
    if (g_vision_cls == null) return;
    g_vision.recognize_text = jni.getStaticMethodID(jenv, cls, "recognize_text", "(JLjava/lang/String;)V");
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core / scanner) ────
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

/// Call `MobVisionBridge.<method>(pid_long, arg)` — async; the result lands
/// later via the deliver thunks. Returns :ok unconditionally.
fn callBridgePidStr(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, arg: ?[*:0]const u8) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jarg: jni.JString = if (arg) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, g_vision_cls, method, pidToJlong(pid), jarg);
    if (jarg != null) jni.deleteLocalRef(jenv, jarg);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Inbound delivery thunks ───────────────────────────────────────────────

// Deliver {:vision, <tag_atom>, <utf8 binary>} to `pid`. Shared by the text
// and error thunks — only the middle atom differs.
fn deliverVisionBinary(jenv: *jni.JNIEnv, pid_long: jni.JLong, comptime tag: [:0]const u8, jstr: jni.JString) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const c = jenv.*.GetStringUTFChars.?(jenv, jstr, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, jstr, c);
    const n = std.mem.len(c);

    var b: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(n, &b) == 0) return;
    @memcpy(b.data[0..n], c[0..n]);

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "vision"),
        erts.atom(env, tag),
        erts.enif_make_binary(env, &b),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// {:vision, :text, binary}
export fn Java_io_mob_vision_MobVisionBridge_nativeDeliverVisionText(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    text: jni.JString,
) callconv(.c) void {
    _ = cls;
    deliverVisionBinary(jenv, pid_long, "text", text);
}

// {:vision, :error, binary}
export fn Java_io_mob_vision_MobVisionBridge_nativeDeliverVisionError(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    reason: jni.JString,
) callconv(.c) void {
    _ = cls;
    deliverVisionBinary(jenv, pid_long, "error", reason);
}

// ── NIFs ──────────────────────────────────────────────────────────────────

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

// argv[0] is the request JSON ({"path":...,"languages":[...]}); passed to the
// bridge unchanged (the Kotlin side parses it). Arity 1 matches the .erl stub.
fn nif_recognize_text(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var jbuf: [4096]u8 = undefined;
    if (!binArgZ(env, argv[0], &jbuf)) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_vision.recognize_text, pid, @ptrCast(&jbuf));
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "recognize_text", .arity = 1, .fptr = nif_recognize_text, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_vision_nif",
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

pub export fn mob_vision_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
