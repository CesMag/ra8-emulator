//! Covers src/chip/core/cpu/instr.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Instr = ra8.chip.core.cpu.instr.Instr;

const Rom = struct {
    bytes: []const u8,

    fn view(self: *Rom) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Rom = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

test "the top five bits pick the width" {
    try std.testing.expect(!Instr.isWide(0xBF00)); // nop
    try std.testing.expect(!Instr.isWide(0xE7FE)); // b .  (0b11100)
    try std.testing.expect(Instr.isWide(0xE92D)); // push.w (0b11101)
    try std.testing.expect(Instr.isWide(0xF3AF)); // nop.w (0b11110)
    try std.testing.expect(Instr.isWide(0xF8D0)); // ldr.w (0b11111)
}

test "fetch reads a second halfword only for a wide encoding" {
    // bf00 nop ; f3af 8000 nop.w
    var rom: Rom = .{ .bytes = &.{ 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80 } };
    const narrow = try Instr.fetch(rom.view(), 0);
    try std.testing.expectEqual(@as(u32, 2), narrow.size);
    const wide = try Instr.fetch(rom.view(), 2);
    try std.testing.expectEqual(@as(u32, 4), wide.size);
    try std.testing.expectEqual(@as(u16, 0x8000), wide.hw2);
    // A wide first halfword at the end of memory has nothing to pair with.
    var cut: Rom = .{ .bytes = &.{ 0x00, 0xBF, 0xAF, 0xF3 } };
    try std.testing.expectError(bus.Error.Unmapped, Instr.fetch(cut.view(), 2));
}

test "an instruction prints its address and halfwords" {
    var buf: [64]u8 = undefined;
    const narrow: Instr = .{ .address = 0x0800_0010, .hw1 = 0xDE00, .size = 2 };
    try std.testing.expectEqualStrings("0x08000010: 0xde00", try std.fmt.bufPrint(&buf, "{f}", .{narrow}));
    const wide: Instr = .{ .address = 0x0800_0012, .hw1 = 0xF7F0, .hw2 = 0xA000, .size = 4 };
    try std.testing.expectEqualStrings("0x08000012: 0xf7f0 0xa000", try std.fmt.bufPrint(&buf, "{f}", .{wide}));
}
