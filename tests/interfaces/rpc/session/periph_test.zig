//! Tests for src/interfaces/rpc/session/periph.zig (RA8EMU-818) on a served
//! image: periph lists the blocks on cpu0's bus and the registers of one
//! block, as text and as JSON, and refuses what it cannot answer.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const periph = ra8.rpc.session.periph;
const handlers = ra8.rpc.session.server;
const app_codes = handlers.app_codes;

const image = "tests/fixtures/fpu/fp_basic.elf";

fn ask(context: *handlers.Context, block: []const u8, json: bool) ![]const u8 {
    return switch (periph.periph(context, .{ .core = .cpu0, .json = @intFromBool(json), .block = block })) {
        .ok => |listed| listed.text,
        .err => |code| if (@backingInt(code) == app_codes.too_long) error.TooLong else error.Refused,
    };
}

test "cpu0's bus lists its blocks, RTC among them, one per line" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image);
    defer opened.deinit();
    const text = try ask(&opened.context, "", false);
    try std.testing.expect(std.mem.indexOf(u8, text, "RTC 0x") != null);
    try std.testing.expectEqual(opened.owner.board().bus.count, std.mem.count(u8, text, "\n"));
}

test "RTC's registers come back with their offsets" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image);
    defer opened.deinit();
    const text = try ask(&opened.context, "RTC", false);
    try std.testing.expect(std.mem.startsWith(u8, text, "r64cnt 0x00 ?\nseccnt 0x02 ?\n"));
    try std.testing.expect(std.mem.endsWith(u8, text, "rcr4 0x28 ?\n"));
    try std.testing.expectError(error.Refused, ask(&opened.context, "nosuch", false));
}

test "the JSON forms parse, with an undeclared width as null" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image);
    defer opened.deinit();
    const gpa = std.testing.allocator;
    const listed = try std.json.parseFromSlice(std.json.Value, gpa, try ask(&opened.context, "", true), .{});
    defer listed.deinit();
    try std.testing.expectEqual(opened.owner.board().bus.count, listed.value.array.items.len);
    const rtc = try std.json.parseFromSlice(std.json.Value, gpa, try ask(&opened.context, "RTC", true), .{});
    defer rtc.deinit();
    const second = rtc.value.object.get("registers").?.array.items[1].object;
    try std.testing.expectEqualStrings("seccnt", second.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), second.get("offset").?.integer);
    try std.testing.expect(second.get("width").? == .null);
}

test "no hook refuses; a listing past the scratch is too long" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image);
    defer opened.deinit();
    const hook = opened.context.peripherals;
    opened.context.peripherals = null;
    try std.testing.expectError(error.Refused, ask(&opened.context, "", false));
    opened.context.peripherals = hook;
    const scratch = opened.context.scratch;
    opened.context.scratch = scratch[0..16];
    defer opened.context.scratch = scratch;
    try std.testing.expectError(error.TooLong, ask(&opened.context, "", false));
}
