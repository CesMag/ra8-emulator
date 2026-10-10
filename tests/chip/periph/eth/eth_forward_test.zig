//! Tests for src/chip/periph/eth/eth_forward.zig.
const std = @import("std");
const ra8 = @import("ra8");
const forward = ra8.chip.periph.eth.forward;

fn reg(offset: u32) u32 {
    return forward.base + offset;
}

fn port(p: u32, word: u32) u32 {
    return reg(forward.off.fwpbfc0 + forward.off.port_stride * p + word);
}

test "an engine nothing touched stays out of the report" {
    var unit: forward.Forward = .{};
    try std.testing.expect(unit.quiet());
}

test "control and enable read back what was written" {
    var unit: forward.Forward = .{};
    unit.write(reg(forward.off.ctrl), 4, 0x1);
    unit.write(reg(forward.off.ie), 4, 0xF0);
    try std.testing.expectEqual(@as(u32, 0x1), unit.read(reg(forward.off.ctrl), 4));
    try std.testing.expectEqual(@as(u32, 0xF0), unit.read(reg(forward.off.ie), 4));
    try std.testing.expect(!unit.quiet());
}

test "ICLR clears the status bits it is given and reads 0" {
    var unit: forward.Forward = .{ .sts = 0x0F };
    unit.write(reg(forward.off.iclr), 4, 0x05);
    try std.testing.expectEqual(@as(u32, 0x0A), unit.read(reg(forward.off.sts), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(forward.off.iclr), 4));
}

test "each port keeps its own PBDV and PBCSD words" {
    var unit: forward.Forward = .{};
    unit.write(port(0, 0), 4, 0x03);
    unit.write(port(0, 4), 4, 0x11);
    unit.write(port(1, 0), 4, 0x05);
    unit.write(port(2, 0), 4, 0x06);
    try std.testing.expectEqual(@as(u32, 0x03), unit.read(port(0, 0), 4));
    try std.testing.expectEqual(@as(u32, 0x11), unit.read(port(0, 4), 4));
    try std.testing.expectEqual(@as(u32, 0x05), unit.read(port(1, 0), 4));
    try std.testing.expectEqual(@as(u32, 0x06), unit.read(port(2, 0), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(port(1, 4), 4));
}

test "the driver's read-modify-write keeps the bits above PBDV" {
    var unit: forward.Forward = .{};
    unit.write(port(1, 0), 4, 0x0001_0000);
    const cur = unit.read(port(1, 0), 4) & ~@as(u32, 0x7F);
    unit.write(port(1, 0), 4, cur | 0x02);
    try std.testing.expectEqual(@as(u32, 0x0001_0002), unit.read(port(1, 0), 4));
}

test "the blocks put every slot on the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit: forward.Forward = .{};
    for (unit.blocks()) |block| try bus.add(block);
    bus.write(reg(forward.off.ctrl), 4, 0x1);
    bus.write(port(2, 4), 4, 0x1F);
    try std.testing.expectEqual(@as(u32, 0x1), unit.ctrl);
    try std.testing.expectEqual(@as(u32, 0x1F), unit.ports[2][1]);
}
