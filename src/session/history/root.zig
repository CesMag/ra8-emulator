//! The history's root record: the frozen identity of the run a history
//! belongs to. It is written once, when the history is created, and never
//! after; a branch or a checkpoint never touches it.
//!
//! A kept history is valid only for the build that recorded it, so the
//! root carries the build's identity (emulator commit, model version and
//! the snapshot format version its config blobs were written in), both
//! ELF images with their identities, and every configuration value that
//! separates one deterministic run from another: the part, board and
//! memory config, the boundary grid and the idle-skip choice, the panel's
//! vsync, the RTC's pace and its resolved start date, the attach and
//! fault lists, the input script and camera policy with their hashes,
//! and the loop-skip flags. A path, the host's wall clock and a pointer
//! are never recorded: a value is recorded or the field is absent.
//!
//! The structured config families (memory config, grid, attach and fault
//! lists) are carried as the byte payloads the snapshot's own sections
//! encode, tagged with the snapshot version in the root, so the record
//! reuses the complete snapshot codec instead of growing a second schema
//! beside it.
//!
//! Every hash in the record is the snapshot's image identity: Blake3
//! truncated to 16 bytes. Decode recomputes each hash over the bytes the
//! record carries and refuses a mismatch, so a corrupted script byte or
//! ELF byte cannot pass as the content it claims.
//!
//! Every number is little-endian.
const std = @import("std");

/// The root record's own version. A reader that does not know it refuses
/// the record: the root has no per-field lengths that would let a reader
/// skip what it does not understand, so any other version would decode
/// into a different shape silently.
pub const version: u32 = 1;

pub const Error = error{ BadVersion, Truncated, BadValue, TooLarge, ImageMismatch };

/// The git commit, 20 raw bytes. Zero-filled when a build cannot prove
/// one (a tarball build, say); whether that is acceptable when a history
/// is opened is the opener's policy, not this codec's.
pub const commit_len: usize = 20;

/// Length caps. Every length is checked against its cap before its bytes
/// are consumed, so a corrupt length can never make a decoder allocate or
/// walk past the record.
pub const max_text: usize = 256;
/// Full board-profile text, using the existing profile grammar and u16
/// length on the wire. Older records remain decodable without rewriting.
pub const max_profile: usize = 4096;
pub const max_blob: usize = 64 * 1024;
pub const max_input: usize = 1024 * 1024;
pub const max_elf: usize = 16 * 1024 * 1024;

/// The identity every hash in the record uses: Blake3 truncated to 16
/// bytes, the identity a snapshot stamps its ELF images with
/// (src/board/snapshot/run.zig).
pub fn identity(bytes: []const u8) [16]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &hash, .{});
    return hash[0..16].*;
}

/// The panel's vsync: off, or one edge's phase and period in nanoseconds
/// of modelled time (R9: one model, applied identically everywhere).
pub const Vsync = struct { phase_ns: u64, period_ns: u64 };

/// The RTC's pace: the geared boundary clock the corpus was recorded on,
/// or the virtual clock that counts modelled nanoseconds.
pub const Pace = enum(u8) { boundary = 0, virtual = 1 };

/// The date and time the RTC was already counting from when the run
/// began: the resolved value of `--rtc-start`, never the request that
/// produced it. A run seeded with `now` resolves once, at creation, and
/// records the calendar it got.
pub const Start = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8 };

/// One ELF image with the identity its bytes hash to.
pub const Image = struct { identity: [16]u8, bytes: []const u8 };

/// The loop-skip flags, as a bit set. Bit 0 is the counted-loop skip the
/// CPU runs (src/chip/core/cpu/fixed_trip.zig). A bit outside this mask
/// is a flag this version does not describe and is refused.
pub const skip_known: u32 = 1;

/// The root record. Slices borrow: from the caller's config on encode and
/// from the record's bytes on decode; nothing is copied or owned.
pub const Root = struct {
    /// The snapshot format version the config blobs were written in.
    snapshot_version: u32,
    emulator_commit: [commit_len]u8 = @splat(0),
    model_version: []const u8 = "",
    part: []const u8 = "",
    board_profile: []const u8 = "",
    memory_config: []const u8 = "",
    grid: []const u8 = "",
    idle_skip: bool = true,
    panel_vsync: ?Vsync = null,
    pace: Pace = .boundary,
    rtc_start: ?Start = null,
    attaches: []const u8 = "",
    faults: []const u8 = "",
    /// The input script's bytes and the identity they hash to.
    input_script: []const u8 = "",
    input_hash: [16]u8 = @splat(0),
    /// The camera source spec and its identity.
    camera: []const u8 = "",
    camera_hash: [16]u8 = @splat(0),
    skip_flags: u32 = 0,
    elf0: Image,
    elf1: ?Image = null,
};

fn checkedLen(comptime W: usize, len: usize) Error!void {
    if (len > W) return Error.TooLarge;
}

/// Rejects a root whose values this version cannot carry, before any
/// byte is written: capped lengths, the known skip bits, and every hash
/// matching the bytes it claims to identify.
pub fn check(root: *const Root) Error!void {
    try checkedLen(max_text, root.model_version.len);
    try checkedLen(max_text, root.part.len);
    try checkedLen(max_profile, root.board_profile.len);
    try checkedLen(max_blob, root.memory_config.len);
    try checkedLen(max_blob, root.grid.len);
    try checkedLen(max_blob, root.attaches.len);
    try checkedLen(max_blob, root.faults.len);
    try checkedLen(max_input, root.input_script.len);
    try checkedLen(max_blob, root.camera.len);
    try checkedLen(max_elf, root.elf0.bytes.len);
    if (root.elf0.bytes.len == 0) return Error.BadValue;
    if (root.elf1) |elf| {
        try checkedLen(max_elf, elf.bytes.len);
        if (elf.bytes.len == 0) return Error.BadValue;
    }
    if (root.skip_flags & ~skip_known != 0) return Error.BadValue;
    if (root.input_script.len > 0 and !matches(root.input_hash, root.input_script)) return Error.ImageMismatch;
    if (root.camera.len > 0 and !matches(root.camera_hash, root.camera)) return Error.ImageMismatch;
    if (!matches(root.elf0.identity, root.elf0.bytes)) return Error.ImageMismatch;
    if (root.elf1) |elf| if (!matches(elf.identity, elf.bytes)) return Error.ImageMismatch;
}

/// Whether `hash` is the identity of `bytes`.
fn matches(hash: [16]u8, bytes: []const u8) bool {
    const got = identity(bytes);
    return std.mem.eql(u8, &hash, &got);
}

pub fn encodedLen(root: *const Root) (std.Io.Writer.Error || Error)!usize {
    try check(root);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try writeAll(root, &counter.writer);
    return counter.fullCount();
}

pub fn encode(root: *const Root, w: *std.Io.Writer) (std.Io.Writer.Error || Error)!void {
    try check(root);
    try writeAll(root, w);
}

fn writeAll(root: *const Root, w: *std.Io.Writer) (std.Io.Writer.Error || Error)!void {
    try w.writeInt(u32, version, .little);
    try w.writeInt(u32, root.snapshot_version, .little);
    try w.writeAll(&root.emulator_commit);
    try writeText(w, root.model_version);
    try writeText(w, root.part);
    try writeText(w, root.board_profile);
    try writeBlob(w, root.memory_config);
    try writeBlob(w, root.grid);
    try w.writeByte(@intFromBool(root.idle_skip));
    if (root.panel_vsync) |vsync| {
        try w.writeByte(1);
        try w.writeInt(u64, vsync.phase_ns, .little);
        try w.writeInt(u64, vsync.period_ns, .little);
    } else try w.writeByte(0);
    try w.writeByte(@backingInt(root.pace));
    if (root.rtc_start) |start| {
        try checkStart(start);
        try w.writeByte(1);
        try w.writeInt(u16, start.year, .little);
        try w.writeByte(start.month);
        try w.writeByte(start.day);
        try w.writeByte(start.hour);
        try w.writeByte(start.minute);
        try w.writeByte(start.second);
    } else try w.writeByte(0);
    try writeBlob(w, root.attaches);
    try writeBlob(w, root.faults);
    try writeBlob(w, root.input_script);
    try w.writeAll(&root.input_hash);
    try writeBlob(w, root.camera);
    try w.writeAll(&root.camera_hash);
    try w.writeInt(u32, root.skip_flags, .little);
    try w.writeByte(@intFromBool(root.elf1 != null));
    try writeBlob(w, root.elf0.bytes);
    try w.writeAll(&root.elf0.identity);
    if (root.elf1) |elf| {
        try writeBlob(w, elf.bytes);
        try w.writeAll(&elf.identity);
    }
}

fn writeText(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try w.writeInt(u16, @intCast(value.len), .little);
    try w.writeAll(value);
}

fn writeBlob(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeInt(u32, @intCast(bytes.len), .little);
    try w.writeAll(bytes);
}

pub fn decode(bytes: []const u8) Error!Root {
    var c: Cursor = .{ .bytes = bytes };
    if (try c.int(u32) != version) return Error.BadVersion;
    var root: Root = .{ .snapshot_version = try c.int(u32), .elf0 = undefined };
    @memcpy(&root.emulator_commit, try c.take(commit_len));
    root.model_version = try readText(&c);
    root.part = try readText(&c);
    root.board_profile = try c.take(try c.length(u16, max_profile));
    root.memory_config = try readBlob(&c, max_blob);
    root.grid = try readBlob(&c, max_blob);
    root.idle_skip = try flag(&c);
    root.panel_vsync = if (try flag(&c))
        .{ .phase_ns = try c.int(u64), .period_ns = try c.int(u64) }
    else
        null;
    const pace_raw = try c.byte();
    if (pace_raw > 1) return Error.BadValue;
    root.pace = @fromBackingInt(@intCast(pace_raw));
    root.rtc_start = if (try flag(&c)) start: {
        const start = Start{
            .year = try c.int(u16),
            .month = try c.byte(),
            .day = try c.byte(),
            .hour = try c.byte(),
            .minute = try c.byte(),
            .second = try c.byte(),
        };
        try checkStart(start);
        break :start start;
    } else null;
    root.attaches = try readBlob(&c, max_blob);
    root.faults = try readBlob(&c, max_blob);
    root.input_script = try readBlob(&c, max_input);
    root.input_hash = (try c.take(16))[0..16].*;
    root.camera = try readBlob(&c, max_blob);
    root.camera_hash = (try c.take(16))[0..16].*;
    root.skip_flags = try c.int(u32);
    if (root.skip_flags & ~skip_known != 0) return Error.BadValue;
    const elf1_present = try flag(&c);
    root.elf0 = try readImage(&c);
    root.elf1 = if (elf1_present) try readImage(&c) else null;
    if (c.at != bytes.len) return Error.BadValue;
    try check(&root);
    return root;
}

/// A bool on the wire is one byte, 0 or 1; anything else is a value this
/// layout never wrote.
fn flag(c: *Cursor) Error!bool {
    const one = try c.byte();
    if (one > 1) return Error.BadValue;
    return one == 1;
}

fn readText(c: *Cursor) Error![]const u8 {
    return c.take(try c.length(u16, max_text));
}

fn readBlob(c: *Cursor, cap: usize) Error![]const u8 {
    return c.take(try c.length(u32, cap));
}

fn readImage(c: *Cursor) Error!Image {
    const bytes = try readBlob(c, max_elf);
    if (bytes.len == 0) return Error.BadValue;
    return .{ .identity = (try c.take(16))[0..16].*, .bytes = bytes };
}

fn checkStart(start: Start) Error!void {
    if (start.month < 1 or start.month > 12) return Error.BadValue;
    if (start.day < 1 or start.day > 31) return Error.BadValue;
    if (start.hour > 23 or start.minute > 59 or start.second > 59) return Error.BadValue;
}

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Cursor, n: usize) Error![]const u8 {
        const rest = self.bytes[self.at..];
        if (n > rest.len) return Error.Truncated;
        self.at += n;
        return rest[0..n];
    }

    fn byte(self: *Cursor) Error!u8 {
        return (try self.take(1))[0];
    }

    fn int(self: *Cursor, comptime T: type) Error!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn length(self: *Cursor, comptime T: type, cap: usize) Error!usize {
        const raw: usize = try self.int(T);
        if (raw > cap) return Error.TooLarge;
        return raw;
    }
};
