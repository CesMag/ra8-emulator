//! Tests for src/interfaces/rpc/session_stack.zig (RA8EMU-816) on a real
//! harness: the reservation comes from the image's linker symbols, a run
//! leaves the low MSP inside it, and an MSP set under the base overflows.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const stack = ra8.rpc.session.stack;
const region_map = ra8.session.region.map;

const image = "tests/fixtures/sections/fault_crashlog_hil.elf";
const base: u32 = 0x220F_DF00;
const size: u32 = 0x2000;

fn stackOf(context: *anyopaque, core: usize) ?region_map.Stack {
    const harness: *ra8.session.harness.Harness = @ptrCast(@alignCast(context));
    const which: ra8.session.api.Core = if (core == 0) .cpu0 else .cpu1;
    const loaded = harness.loadedImage(which) orelse return null;
    return region_map.stackOf(loaded, &region_map.ek_ra8d2);
}

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoImage;
}

fn ask(context: *server.Context) !ra8.rpc.session.rpc.StackReport {
    return switch (stack.stack(context, .{ .core = .cpu0 })) {
        .ok => |report| report,
        .err => error.Refused,
    };
}

test "a run keeps the low MSP inside the image's reservation" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    context.mapping = .{ .context = &opened, .mapFn = noMap, .stackFn = stackOf };
    opened.session().live.budget = 2_000;
    _ = try opened.session().run(.cpu0, .cont);
    const report = try ask(&context);
    try std.testing.expectEqual(@as(u8, 1), report.has_stack);
    try std.testing.expectEqual(base, report.base);
    try std.testing.expectEqual(size, report.size);
    try std.testing.expect(report.low_msp <= report.msp);
    try std.testing.expectEqual(@as(u32, 0), report.overflow);
}

test "an MSP set under the base reports the overflow in bytes" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    context.mapping = .{ .context = &opened, .mapFn = noMap, .stackFn = stackOf };
    try opened.session().setRegister(.cpu0, .msp, base - 0x40);
    try opened.session().setRegister(.cpu0, .msp, base + 0x100);
    const report = try ask(&context);
    try std.testing.expectEqual(base - 0x40, report.low_msp);
    try std.testing.expectEqual(@as(u32, 0x40), report.overflow);
}

test "with no stack hook the report carries no reservation" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    const report = try ask(&context);
    try std.testing.expectEqual(@as(u8, 0), report.has_stack);
    try std.testing.expectEqual(@as(u32, 0), report.overflow);
}
