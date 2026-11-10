//! Tests for src/interfaces/rpc/session/disasm.zig on a real firmware fixture.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const disasm_wire = ra8.rpc.session.disasm_wire;
const handler = ra8.rpc.session.disasm;

const image_path = "tests/fixtures/uart/uart_irq_echo.elf";
const sci_init: u32 = 0x0200_1974;

fn imageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const harness: *ra8.session.harness.Harness = @ptrCast(@alignCast(context));
    return harness.loadedImage(if (core == 0) .cpu0 else .cpu1);
}

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoImage;
}

test "Method opcode disasm is 0x013D and routed in server" {
    try std.testing.expectEqual(@as(u16, 0x013D), @backingInt(proto.Method.disasm));
    var found = false;
    inline for (server.routes) |route| {
        if (route[0] == @backingInt(proto.Method.disasm)) found = true;
    }
    try std.testing.expect(found);
}

test "disasm decodes instructions forward from PC with symbol entry label" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();

    const session = opened.session();
    _ = try session.setBreakpoint(.cpu0, .{ .address = sci_init });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);

    var scratch: [disasm_wire.disasm_bytes]u8 = undefined;
    var context: server.Context = .{
        .session = session,
        .scratch = &scratch,
        .mapping = .{ .context = &opened, .mapFn = noMap, .imageFn = imageOf },
    };

    const reply = switch (handler.disasm(&context, .{ .core = .cpu0, .count = 8, .use_pc = 1 })) {
        .ok => |r| r,
        .err => return error.Refused,
    };

    try std.testing.expectEqual(proto.Core.cpu0, reply.core);
    try std.testing.expectEqual(sci_init, reply.pc);
    try std.testing.expectEqual(@as(u8, 8), reply.count);

    var reader: disasm_wire.Reader = .{ .rest = reply.rows };
    const first = (try reader.next()).?;
    try std.testing.expectEqual(sci_init, first.address);
    try std.testing.expectEqual(@as(u8, 1), first.decoded);
    try std.testing.expect(first.text.len > 0);
    try std.testing.expectEqualStrings("ra8_sci_init", first.symbol);
}

test "disasm refuses unattached CPU1 with no_core" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();

    var scratch: [disasm_wire.disasm_bytes]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    switch (handler.disasm(&context, .{ .core = .cpu1, .count = 4, .use_pc = 1 })) {
        .ok => return error.ExpectedRefusal,
        .err => |code| try std.testing.expectEqual(@as(u16, proto.app_codes.no_core), @backingInt(code)),
    }
}
