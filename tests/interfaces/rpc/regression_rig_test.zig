//! Bounds and whole-state coverage for the single-core replay fixture.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("regression_rig.zig");
const Harness = ra8.session.harness.Harness;
const gpa = std.testing.allocator;
const memmap = ra8.chip.core.memmap;

test "the single-core recording retains its explicit small profile" {
    const recorded = try rig.Recorded.open(gpa, 1);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const root = try ra8.session.history_root.decode(bytes);
    try std.testing.expectEqualStrings(rig.small_profile, root.board_profile);
}

test "the replay fixture image fits its configured memory" {
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = rig.image, .board_profile = rig.small_profile });
    defer opened.deinit();
    try std.testing.expectEqual(@as(u32, 1 << 20), opened.state.profile.memory.ospi.size);
    try std.testing.expectEqual(@as(u32, 1 << 20), opened.state.profile.memory.sdram.size);
    const store = &opened.state.cpu0.store.?;
    const image = try ra8.board.image.load.read(opened.state.image);
    try std.testing.expect(image.count > 0);
    for (image.maps.items()) |range| try std.testing.expect(store.span(range.base, range.size()) != null);
    for (image.segments[0..image.count]) |segment| {
        try std.testing.expectEqualSlices(u8, segment.bytes, store.span(segment.paddr, segment.bytes.len).?);
    }
}

test "the small replay profile changes only external memory sizes" {
    const profile = ra8.board.profile;
    var expected = try profile.parse(profile.ek_ra8d2);
    expected.memory.ospi.size = 1 << 20;
    expected.memory.sdram.size = 1 << 20;
    const actual = try profile.parse(rig.small_profile);
    try std.testing.expectEqualDeep(expected.memory, actual.memory);
    try std.testing.expectEqualDeep(expected.fits[0..expected.count], actual.fits[0..actual.count]);
    try std.testing.expectEqualDeep(expected.leds[0..expected.led_count], actual.leds[0..actual.led_count]);
    try std.testing.expectEqualDeep(expected.switches[0..expected.switch_count], actual.switches[0..actual.switch_count]);
    try std.testing.expectEqualDeep(expected.panel, actual.panel);
}

test "replay fixture snapshots cover external memory endpoints and CPU and board state" {
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = rig.image, .board_profile = rig.small_profile });
    defer opened.deinit();
    const base = try snapshot(&opened);
    defer gpa.free(base);
    const before = digest(base);
    const memory = opened.state.profile.memory;
    const addresses = [_]u32{
        memmap.sdram_base,
        memmap.sdram_base + memory.sdram.size - 1,
        0x8000_0000,
        0x8000_0000 + memory.ospi.size - 1,
    };
    for (addresses) |address| {
        try opened.guest().write(address, &.{0x5a});
        try expectChanged(&opened, before);
        try restoreExact(&opened, base);
    }
    opened.primaryCpu().regs.low[3] ^= 1;
    try expectChanged(&opened, before);
    try restoreExact(&opened, base);
    opened.state.board.time.base.cycles += 1;
    try expectChanged(&opened, before);
    try restoreExact(&opened, base);
}

fn snapshot(opened: *Harness) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try opened.state.files.writeTo(&out.writer);
    return gpa.dupe(u8, out.written());
}

fn digest(bytes: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &hash, .{});
    return hash;
}

fn expectChanged(opened: *Harness, before: [32]u8) !void {
    const bytes = try snapshot(opened);
    defer gpa.free(bytes);
    try std.testing.expect(!std.mem.eql(u8, &before, &digest(bytes)));
}

fn restoreExact(opened: *Harness, base: []const u8) !void {
    try opened.state.files.readFrom(base);
    const restored = try snapshot(opened);
    defer gpa.free(restored);
    try std.testing.expectEqualSlices(u8, base, restored);
}
