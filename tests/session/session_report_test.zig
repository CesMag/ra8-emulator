//! Tests for src/session/session_report.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const session_report = ra8.session.step_hook.session_report;

/// 64 bytes of RAM at address 0, the vector table first.
const Ram = struct {
    bytes: [64]u8,

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

// sp 0x40, reset 0x09 ; 0x08 bf00 nop ; 0x0A f3af 8000 nop.w
fn ram() Ram {
    var r: Ram = .{ .bytes = @as([64]u8, @splat(0)) };
    const image = [_]u8{ 0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80 };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

test "an address with no image is eight hex digits" {
    var text: [64]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&text);
    try session_report.where(null, 0x2200_0018, &stream);
    try std.testing.expectEqualStrings("0x22000018", stream.buffered());
}

test "a stop line names the address and the instruction there on the Zig core" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var text: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&text);
    try session_report.line(.{ .zig = .{ .cpu = &cpu } }, null, 0x08, &stream);
    try std.testing.expect(std.mem.startsWith(u8, stream.buffered(), "0x00000008: nop"));
}

test "a backtrace without unwind tables is the pc and lr" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    cpu.regs.lr = 0x0B;
    var text: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&text);
    try session_report.backtrace(.{ .zig = .{ .cpu = &cpu } }, null, &stream);
    try std.testing.expectEqualStrings("#0 0x00000008\n#1 0x0000000A\n", stream.buffered());
}
