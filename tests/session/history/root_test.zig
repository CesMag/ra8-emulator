//! Covers src/session/history/root.zig: the frozen root record, its
//! length caps, the identity every hash carries, and what decode refuses.
const std = @import("std");
const ra8 = @import("ra8");
const root = ra8.session.history_root;

const elf0 = "elf-zero bytes";
const elf1 = "elf-one bytes";

fn sample() root.Root {
    return .{
        .snapshot_version = 13,
        .emulator_commit = @splat(7),
        .model_version = "ra8m1",
        .part = "R7FA8M1AHECBD",
        .board_profile = "c6-dev",
        .memory_config = "memory config bytes",
        .grid = "grid bytes",
        .idle_skip = true,
        .panel_vsync = .{ .phase_ns = 1_500, .period_ns = 16_666_666 },
        .pace = .virtual,
        .rtc_start = .{ .year = 2026, .month = 10, .day = 13, .hour = 21, .minute = 4, .second = 59 },
        .attaches = "attach list bytes",
        .faults = "fault list bytes",
        .input_script = "tap 100 10 20",
        .input_hash = root.identity("tap 100 10 20"),
        .camera = "test:pattern",
        .camera_hash = root.identity("test:pattern"),
        .skip_flags = 1,
        .elf0 = .{ .identity = root.identity(elf0), .bytes = elf0 },
        .elf1 = .{ .identity = root.identity(elf1), .bytes = elf1 },
    };
}

fn encoded(r: root.Root) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try root.encode(&r, &buf.writer);
    return std.testing.allocator.dupe(u8, buf.written());
}

test "a full root record round trips through its layout" {
    const want = sample();
    const bytes = try encoded(want);
    defer std.testing.allocator.free(bytes);
    const got = try root.decode(bytes);
    try std.testing.expectEqual(want.snapshot_version, got.snapshot_version);
    try std.testing.expectEqual(want.emulator_commit, got.emulator_commit);
    try std.testing.expectEqualStrings(want.model_version, got.model_version);
    try std.testing.expectEqualStrings(want.part, got.part);
    try std.testing.expectEqualStrings(want.board_profile, got.board_profile);
    try std.testing.expectEqualStrings(want.memory_config, got.memory_config);
    try std.testing.expectEqualStrings(want.grid, got.grid);
    try std.testing.expectEqual(want.idle_skip, got.idle_skip);
    try std.testing.expectEqual(want.panel_vsync, got.panel_vsync);
    try std.testing.expectEqual(want.pace, got.pace);
    try std.testing.expectEqual(want.rtc_start, got.rtc_start);
    try std.testing.expectEqualStrings(want.attaches, got.attaches);
    try std.testing.expectEqualStrings(want.faults, got.faults);
    try std.testing.expectEqualStrings(want.input_script, got.input_script);
    try std.testing.expectEqual(want.input_hash, got.input_hash);
    try std.testing.expectEqualStrings(want.camera, got.camera);
    try std.testing.expectEqual(want.camera_hash, got.camera_hash);
    try std.testing.expectEqual(want.skip_flags, got.skip_flags);
    try std.testing.expectEqualStrings(want.elf0.bytes, got.elf0.bytes);
    try std.testing.expectEqual(want.elf0.identity, got.elf0.identity);
    try std.testing.expectEqualStrings(want.elf1.?.bytes, got.elf1.?.bytes);
    try std.testing.expectEqual(want.elf1.?.identity, got.elf1.?.identity);
}

test "a full board profile uses its own cap without relaxing text caps" {
    var r = sample();
    r.board_profile = ra8.board.profile.ek_ra8d2;
    try std.testing.expect(r.board_profile.len > root.max_text);
    const bytes = try encoded(r);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(r.board_profile, (try root.decode(bytes)).board_profile);
    const too_long: [root.max_profile + 1]u8 = @splat('x');
    r.board_profile = &too_long;
    try std.testing.expectError(error.TooLarge, encoded(r));
}

test "encodedLen matches the bytes encode writes" {
    for ([_]root.Root{ sample(), .{ .snapshot_version = 13, .elf0 = .{ .identity = root.identity(elf0), .bytes = elf0 } } }) |r| {
        const bytes = try encoded(r);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(bytes.len, try root.encodedLen(&r));
    }
}

test "a root without cpu1 or the optional fields round trips" {
    const want: root.Root = .{ .snapshot_version = 13, .elf0 = .{ .identity = root.identity(elf0), .bytes = elf0 } };
    const bytes = try encoded(want);
    defer std.testing.allocator.free(bytes);
    const got = try root.decode(bytes);
    try std.testing.expectEqual(true, got.idle_skip);
    try std.testing.expect(got.panel_vsync == null);
    try std.testing.expectEqual(root.Pace.boundary, got.pace);
    try std.testing.expect(got.rtc_start == null);
    try std.testing.expect(got.elf1 == null);
    try std.testing.expectEqualStrings(want.elf0.bytes, got.elf0.bytes);
}

test "decode recomputes every identity and refuses a mismatch" {
    var r = sample();
    r.elf0.identity[0] ^= 0xff;
    try std.testing.expectError(error.ImageMismatch, encoded(r));
    var r2 = sample();
    r2.input_hash[0] ^= 0xff;
    try std.testing.expectError(error.ImageMismatch, encoded(r2));
    var r3 = sample();
    r3.camera_hash[0] ^= 0xff;
    try std.testing.expectError(error.ImageMismatch, encoded(r3));
    var r4 = sample();
    r4.elf1.?.identity[0] ^= 0xff;
    try std.testing.expectError(error.ImageMismatch, encoded(r4));
    const bytes = try encoded(sample());
    defer std.testing.allocator.free(bytes);
    var copy = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(copy);
    copy[std.mem.indexOf(u8, copy, elf0).?] ^= 0xff;
    try std.testing.expectError(error.ImageMismatch, root.decode(copy));
}

test "encode refuses a length outside its cap and unknown skip bits" {
    var r = sample();
    const long_text: [257]u8 = @splat('x');
    r.model_version = &long_text;
    try std.testing.expectError(error.TooLarge, encoded(r));
    var r2 = sample();
    r2.skip_flags = 2;
    try std.testing.expectError(error.BadValue, encoded(r2));
}

test "an unknown version is refused" {
    var bytes = try encoded(sample());
    defer std.testing.allocator.free(bytes);
    bytes[0] = root.version + 1;
    try std.testing.expectError(error.BadVersion, root.decode(bytes));
}

test "every truncation of a root record is refused" {
    const bytes = try encoded(sample());
    defer std.testing.allocator.free(bytes);
    for (0..bytes.len) |cut| {
        try std.testing.expectError(error.Truncated, root.decode(bytes[0..cut]));
    }
    _ = try root.decode(bytes);
}

test "oversized lengths and trailing bytes are refused" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeInt(u32, root.version, .little);
    try w.writeInt(u32, 13, .little);
    try w.writeAll(&@as([root.commit_len]u8, @splat(0)));
    try w.writeInt(u16, root.max_text + 1, .little);
    try std.testing.expectError(error.TooLarge, root.decode(buf.written()));
    const bytes = try encoded(sample());
    defer std.testing.allocator.free(bytes);
    var trailing: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer trailing.deinit();
    try trailing.writer.writeAll(bytes);
    try trailing.writer.writeByte(0);
    try std.testing.expectError(error.BadValue, root.decode(trailing.written()));
}

/// A hand-built record with every optional field absent, so a test can
/// name exactly the field it corrupts.
fn handBuilt(w: *std.Io.Writer, idle: u8, vsync_present: u8, pace: u8, skip_flags: u32, elf1_present: u8) !void {
    try w.writeInt(u32, root.version, .little);
    try w.writeInt(u32, 13, .little);
    try w.writeAll(&@as([root.commit_len]u8, @splat(0)));
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeByte(idle);
    try w.writeByte(vsync_present);
    try w.writeByte(pace);
    try w.writeByte(0); // start absent
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeAll(&root.identity(""));
    try w.writeInt(u32, 0, .little);
    try w.writeAll(&root.identity(""));
    try w.writeInt(u32, skip_flags, .little);
    try w.writeByte(elf1_present);
    try w.writeInt(u32, elf0.len, .little);
    try w.writeAll(elf0);
    try w.writeAll(&root.identity(elf0));
}

test "a bad pace, idle byte, elf presence or skip bit is refused" {
    inline for (.{ "pace", "idle", "elf1", "skip" }) |which| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();
        if (comptime std.mem.eql(u8, which, "pace")) {
            try handBuilt(&buf.writer, 1, 0, 2, 0, 0);
        } else if (comptime std.mem.eql(u8, which, "idle")) {
            try handBuilt(&buf.writer, 2, 0, 0, 0, 0);
        } else if (comptime std.mem.eql(u8, which, "elf1")) {
            try handBuilt(&buf.writer, 1, 0, 0, 0, 2);
        } else {
            try handBuilt(&buf.writer, 1, 0, 0, 2, 0);
        }
        try std.testing.expectError(error.BadValue, root.decode(buf.written()));
    }
    var r = sample();
    r.rtc_start = .{ .year = 2026, .month = 13, .day = 0, .hour = 24, .minute = 60, .second = 60 };
    try std.testing.expectError(error.BadValue, encoded(r));
}

test "the identity is blake3 truncated to its first 16 bytes" {
    var full: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash("abc", &full, .{});
    try std.testing.expectEqual(full[0..16].*, root.identity("abc"));
    try std.testing.expectEqual(root.identity("abc"), root.identity("abc"));
}

test "an empty elf image is refused" {
    var r = sample();
    r.elf0 = .{ .identity = root.identity(""), .bytes = "" };
    try std.testing.expectError(error.BadValue, encoded(r));
    var r2 = sample();
    r2.elf1 = .{ .identity = root.identity(""), .bytes = "" };
    try std.testing.expectError(error.BadValue, encoded(r2));
}

test "version one roots remain decodable without an initial media reference" {
    var r = sample();
    r.media = null;
    const bytes = try encoded(r);
    defer std.testing.allocator.free(bytes);
    std.mem.writeInt(u32, bytes[0..4], 1, .little);
    const old = try root.decode(bytes[0 .. bytes.len - 1]);
    try std.testing.expect(old.media == null);
    r.media = @splat(0x71);
    const current = try encoded(r);
    defer std.testing.allocator.free(current);
    try std.testing.expectEqual(r.media, (try root.decode(current)).media);
}
