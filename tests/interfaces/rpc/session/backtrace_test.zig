//! Tests for src/interfaces/rpc/session/backtrace.zig (RA8EMU-1125) on the
//! uart_irq_echo fixture, the one image with .debug_frame, .debug_line and
//! .symtab: a core stopped inside ra8_sci_init walks out through its callers
//! with names and lines, a server holding no image still answers the pcs,
//! and a core with no image loaded is refused.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const backtrace_wire = ra8.rpc.backtrace_wire;
const handler = ra8.rpc.session.backtrace;

const image_path = "tests/fixtures/uart/uart_irq_echo.elf";
/// ra8_sci_init's first instruction (its symbol is 0x02001975).
const sci_init: u32 = 0x0200_1974;

fn imageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const harness: *ra8.session.harness.Harness = @ptrCast(@alignCast(context));
    return harness.loadedImage(if (core == 0) .cpu0 else .cpu1);
}

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoImage;
}

/// The fixture stopped on ra8_sci_init's first instruction.
fn stopped() !ra8.session.harness.Harness {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    errdefer opened.deinit();
    const session = opened.session();
    _ = try session.setBreakpoint(.cpu0, .{ .address = sci_init });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);
    try std.testing.expectEqual(sci_init, try session.register(.cpu0, .pc));
    return opened;
}

const Walked = struct {
    count: usize = 0,
    frames: [proto.backtrace_frames]proto.StackFrame = undefined,
};

/// Ask for `core`'s chain; `named` hands the server the loaded image.
fn ask(opened: *ra8.session.harness.Harness, scratch: []u8, core: proto.Core, named: bool) !Walked {
    var context: server.Context = .{ .session = opened.session(), .scratch = scratch };
    if (named) context.mapping = .{ .context = opened, .mapFn = noMap, .imageFn = imageOf };
    const chain = switch (handler.backtrace(&context, .{ .core = core })) {
        .ok => |found| found,
        .err => return error.Refused,
    };
    try std.testing.expectEqual(core, chain.core);
    var walked: Walked = .{};
    var reader: backtrace_wire.Reader = .{ .rest = chain.frames };
    while (try reader.next()) |frame| : (walked.count += 1) walked.frames[walked.count] = frame;
    try std.testing.expectEqual(@as(usize, chain.count), walked.count);
    return walked;
}

test "a stop inside ra8_sci_init walks out through its callers with lines" {
    var opened = try stopped();
    defer opened.deinit();
    var scratch: [proto.backtrace_bytes]u8 = undefined;
    const walked = try ask(&opened, &scratch, .cpu0, true);
    try std.testing.expectEqual(@as(usize, 4), walked.count);
    const top = walked.frames[0];
    try std.testing.expectEqual(sci_init, top.pc);
    try std.testing.expectEqualStrings("ra8_sci_init", top.name);
    try std.testing.expectEqual(@as(u32, 0), top.offset);
    try std.testing.expectEqualStrings("ra8_sci.c", top.file);
    try std.testing.expectEqual(@as(u32, 253), top.line);
    for (walked.frames[0..walked.count]) |frame| {
        try std.testing.expect(frame.name.len != 0);
        try std.testing.expectEqual(@as(u8, 0), frame.interrupted);
    }
    const callers = [_][]const u8{ "uart_irq_setup_or_halt", "main", "Reset_Handler" };
    const lines = [_]u32{ 275, 299, 529 };
    for (callers, lines, walked.frames[1..4]) |called, line, frame| {
        try std.testing.expectEqualStrings(called, frame.name);
        try std.testing.expectEqual(line, frame.line);
        try std.testing.expect(frame.offset != 0);
    }
}

test "a server holding no image still answers the pcs" {
    var opened = try stopped();
    defer opened.deinit();
    var named_scratch: [proto.backtrace_bytes]u8 = undefined;
    var bare_scratch: [proto.backtrace_bytes]u8 = undefined;
    const named = try ask(&opened, &named_scratch, .cpu0, true);
    const bare = try ask(&opened, &bare_scratch, .cpu0, false);
    try std.testing.expect(bare.count >= 1);
    try std.testing.expectEqual(named.frames[0].pc, bare.frames[0].pc);
    for (bare.frames[0..bare.count]) |frame| {
        try std.testing.expectEqual(@as(usize, 0), frame.name.len);
        try std.testing.expectEqual(@as(u32, 0), frame.line);
    }
}

test "a core with no image loaded is refused" {
    var opened = try stopped();
    defer opened.deinit();
    var scratch: [proto.backtrace_bytes]u8 = undefined;
    try std.testing.expectError(error.Refused, ask(&opened, &scratch, .cpu1, true));
}

test "a scratch too small for a full chain is refused" {
    var opened = try stopped();
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.Refused, ask(&opened, &scratch, .cpu0, true));
}
