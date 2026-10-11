//! Tests for src/session/txm_debug.zig: a loaded instance picks its paired
//! ELF by name and places its code, an unload drops it, and a reused
//! instance address takes the later load. The ThreadX fixture stands in
//! for a module ELF linked at 0x0200_0000.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const txm_debug = ra8.session.txm_debug;
const txm_symbols = ra8.session.txm_symbols;

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
    var table: txm_debug.Table = .{ .pairs = &.{.{ .label = label, .image = image }} };
    try std.testing.expect(table.loaded(instance, label, placed));
    const want = txm_symbols.Module.at(image, placed).?.addressOf(function).?;
    try std.testing.expectEqual(want, table.addressOf(function).?);
    const found = table.inside(want & ~@as(u32, 1)).?;
    try std.testing.expectEqualStrings(function, found.name);
}

test "an instance with no pair of its name is not placed" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    var table: txm_debug.Table = .{ .pairs = &.{.{ .label = label, .image = try elf.Image.init(bytes) }} };
    try std.testing.expect(!table.loaded(instance, "Fault M33", placed));
    try std.testing.expectEqual(@as(?u32, null), table.addressOf(function));
}

test "an unload drops the module's names" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    var table: txm_debug.Table = .{ .pairs = &.{.{ .label = label, .image = try elf.Image.init(bytes) }} };
    try std.testing.expect(table.loaded(instance, label, placed));
    table.unloaded(instance);
    try std.testing.expectEqual(@as(?u32, null), table.addressOf(function));
    try std.testing.expectEqual(@as(usize, 0), table.count);
}

test "a reused instance address takes the later load" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    const image = try elf.Image.init(bytes);
    var table: txm_debug.Table = .{ .pairs = &.{.{ .label = label, .image = image }} };
    try std.testing.expect(table.loaded(instance, label, placed));
    try std.testing.expect(table.loaded(instance, label, placed + 0x1000));
    try std.testing.expectEqual(@as(usize, 1), table.count);
    const want = txm_symbols.Module.at(image, placed + 0x1000).?.addressOf(function).?;
    try std.testing.expectEqual(want, table.addressOf(function).?);
}
