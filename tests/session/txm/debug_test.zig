//! Tests for src/session/txm/debug.zig: a loaded instance picks its paired
//! ELF by name and places its code, an unload drops it, and a reused
//! instance address takes the later load. The ThreadX fixture stands in
//! for a module ELF linked at 0x0200_0000.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const debug = ra8.session.txm.debug;
const txm_symbols = ra8.session.txm.symbols;

const fixture = "tests/fixtures/threadx/threadx_stkof.elf";
const instance: u32 = 0x2200_5080;
const placed: u32 = 0x2200_10a0;
const label = "Hello M33";
const function = "tx_application_define";

fn read() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture, std.testing.allocator, .limited(1 << 24));
}

test "a loaded instance named like a pair resolves that ELF's code where it runs" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    const image = try elf.Image.init(bytes);
    var table: debug.Table = .{ .pairs = &.{.{ .label = label, .image = image }} };
    try std.testing.expect(table.loaded(instance, label, placed));
    const want = txm_symbols.Module.at(image, placed).?.addressOf(function).?;
    try std.testing.expectEqual(want, table.addressOf(function).?);
    const found = table.inside(want & ~@as(u32, 1)).?;
    try std.testing.expectEqualStrings(function, found.name);
}

test "an instance with no pair of its name is not placed" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    var table: debug.Table = .{ .pairs = &.{.{ .label = label, .image = try elf.Image.init(bytes) }} };
    try std.testing.expect(!table.loaded(instance, "Fault M33", placed));
    try std.testing.expectEqual(@as(?u32, null), table.addressOf(function));
}

test "an unload drops the module's names" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    var table: debug.Table = .{ .pairs = &.{.{ .label = label, .image = try elf.Image.init(bytes) }} };
    try std.testing.expect(table.loaded(instance, label, placed));
    table.unloaded(instance);
    try std.testing.expectEqual(@as(?u32, null), table.addressOf(function));
    try std.testing.expectEqual(@as(usize, 0), table.count);
}

test "a reused instance address takes the later load" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    const image = try elf.Image.init(bytes);
    var table: debug.Table = .{ .pairs = &.{.{ .label = label, .image = image }} };
    try std.testing.expect(table.loaded(instance, label, placed));
    try std.testing.expect(table.loaded(instance, label, placed + 0x1000));
    try std.testing.expectEqual(@as(usize, 1), table.count);
    const want = txm_symbols.Module.at(image, placed + 0x1000).?.addressOf(function).?;
    try std.testing.expectEqual(want, table.addressOf(function).?);
}

const fake = struct {
    var state: u8 = 0;
    var armed: usize = 0;
    var dropped: usize = 0;
    var last: u32 = 0;
    fn reset() void {
        armed = 0;
        dropped = 0;
        last = 0;
    }
    fn arm(ctx: *anyopaque, of: debug.Core, address: u32) anyerror!u32 {
        _ = ctx;
        _ = of;
        armed += 1;
        last = address;
        return 900 + @as(u32, @intCast(armed));
    }
    fn drop(ctx: *anyopaque, of: debug.Core, id: u32) anyerror!void {
        _ = ctx;
        _ = of;
        _ = id;
        dropped += 1;
    }
};

fn withArmer(table: *debug.Table) void {
    table.armer = .{ .ctx = @ptrCast(&fake.state), .arm = fake.arm, .drop = fake.drop };
}

test "a break named before its module loads arms when the module does" {
    fake.reset();
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    const image = try elf.Image.init(bytes);
    var pairs = [_]debug.Pair{.{ .label = label, .image = image }};
    var table: debug.Table = .{ .pairs = &pairs };
    withArmer(&table);
    const id = try table.deferBreak(.cpu0, function);
    try std.testing.expectEqual(debug.pending_base, id);
    try std.testing.expectEqual(@as(usize, 0), fake.armed);
    try std.testing.expect(table.loaded(instance, label, placed));
    try std.testing.expectEqual(@as(usize, 1), fake.armed);
    const want = txm_symbols.Module.at(image, placed).?.addressOf(function).?;
    try std.testing.expectEqual(want & ~@as(u32, 1), fake.last & ~@as(u32, 1));
}

test "an unload drops the armed break and the pending entry stays" {
    fake.reset();
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    var pairs = [_]debug.Pair{.{ .label = label, .image = try elf.Image.init(bytes) }};
    var table: debug.Table = .{ .pairs = &pairs };
    withArmer(&table);
    const id = try table.deferBreak(.cpu0, function);
    _ = table.loaded(instance, label, placed);
    table.unloaded(instance);
    try std.testing.expectEqual(@as(usize, 1), fake.dropped);
    _ = table.loaded(instance, label, placed);
    try std.testing.expectEqual(@as(usize, 2), fake.armed);
    try std.testing.expect(table.remove(id));
    try std.testing.expectEqual(@as(usize, 2), fake.dropped);
    try std.testing.expect(!table.remove(id));
}

test "a pending name longer than the cap is refused" {
    var table: debug.Table = .{ .pairs = &.{} };
    const long = try std.testing.allocator.alloc(u8, debug.max_name + 1);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    try std.testing.expectError(error.NameTooLong, table.deferBreak(.cpu0, long));
}
