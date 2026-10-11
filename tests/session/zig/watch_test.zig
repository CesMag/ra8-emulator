//! Covers src/session/zig/watch.zig: `--watch` on a `--cpu zig` run
//! records each store that starts in the watched word, stamped with the
//! instruction that made it (RA8EMU-639).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const bus = ra8.chip.core.cpu.bus;
const boot = ra8.chip.core.cpu.boot;
const cpu = ra8.chip.core.cpu.cpu;
const zig_watch = cli_app.zig.run.zig_watch;
const Recorder = zig_watch.Recorder;

const place: u32 = 0x2204_00A0;

/// A bus with nothing behind it but a count of what reached it.
const Floor = struct {
    writes: usize = 0,
    reads: usize = 0,
    latched: u32 = 0,

    fn view(self: *Floor) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .latch = latch } };
    }

    fn read(ctx: *anyopaque, _: u32, into: []u8) bus.Error!void {
        const self: *Floor = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        @memset(into, 0);
    }

    fn write(ctx: *anyopaque, _: u32, _: []const u8) bus.Error!void {
        const self: *Floor = @ptrCast(@alignCast(ctx));
        self.writes += 1;
    }

    fn latch(ctx: *anyopaque, _: u32, bits: u32) bus.Error!void {
        const self: *Floor = @ptrCast(@alignCast(ctx));
        self.latched |= bits;
    }
};

/// An ELF header with no sections: enough for a literal place.
fn blankImage(buffer: *[@sizeOf(ra8.board.image.elf.Header)]u8) !ra8.board.image.elf.Image {
    @memset(buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header = std.mem.bytesAsValue(ra8.board.image.elf.Header, buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    return ra8.board.image.elf.Image.init(buffer);
}

/// A recorder armed on `place`, its bus over `floor`, with `regs` lent.
fn armed(recorder: *Recorder, floor: *Floor, regs: *const boot.Regs, ticks: *const u64) !bus.Bus {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    const image = try blankImage(&buffer);
    const wrap = recorder.arm(image, "0x220400A0", null, ticks) orelse return error.NotArmed;
    if (wrap.regsFn) |lend| lend(wrap.context, regs);
    return wrap.busFn(wrap.context, floor.view());
}

test "a store in the word is held until its instruction retires, then logged with that pc" {
    var recorder: Recorder = .{};
    var floor: Floor = .{};
    var regs: boot.Regs = .{ .lr = 0x0200_0101, .pc = 0x0200_0044 };
    const ticks: u64 = 7;
    const view = try armed(&recorder, &floor, &regs, &ticks);
    try view.writeWord(place, 0x1234_5678);
    try std.testing.expectEqual(@as(usize, 1), floor.writes);
    try std.testing.expectEqual(@as(usize, 0), recorder.watched.seen);
    const listener = recorder.listener(null) orelse return error.NoListener;
    listener.instruction(0x0200_0040);
    const one = recorder.watched.opening()[0];
    try std.testing.expectEqual(@as(usize, 1), recorder.watched.seen);
    try std.testing.expectEqual(@as(u32, 0x0200_0040), one.pc);
    try std.testing.expectEqual(@as(u32, 0x0200_0101), one.lr);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), one.value);
    try std.testing.expectEqual(@as(u8, 4), one.width);
    try std.testing.expectEqual(@as(u64, 7), one.when);
}

test "a store outside the word passes through unlogged, and reads are never logged" {
    var recorder: Recorder = .{};
    var floor: Floor = .{};
    var regs: boot.Regs = .{};
    const ticks: u64 = 0;
    const view = try armed(&recorder, &floor, &regs, &ticks);
    try view.writeWord(place + 4, 1);
    try view.writeWord(place - 4, 2);
    _ = try view.readWord(place);
    const log = recorder.result(0) orelse return error.NotArmed;
    try std.testing.expectEqual(@as(usize, 0), log.seen);
    try std.testing.expectEqual(@as(usize, 2), floor.writes);
    try std.testing.expectEqual(@as(usize, 1), floor.reads);
}

test "a byte store inside the word keeps its width and offset" {
    var recorder: Recorder = .{};
    var floor: Floor = .{};
    var regs: boot.Regs = .{};
    const ticks: u64 = 0;
    const view = try armed(&recorder, &floor, &regs, &ticks);
    const byte = [_]u8{0xAB};
    try view.vtable.write(view.ctx, place + 2, &byte);
    const log = recorder.result(0x0200_0010) orelse return error.NotArmed;
    try std.testing.expectEqual(@as(usize, 1), log.seen);
    try std.testing.expectEqual(@as(u8, 1), log.opening()[0].width);
    try std.testing.expectEqual(@as(u8, 2), log.opening()[0].offset);
    try std.testing.expectEqual(@as(u32, 0x0200_0010), log.opening()[0].pc);
}

test "a status latch passes straight through and is no store" {
    var recorder: Recorder = .{};
    var floor: Floor = .{};
    var regs: boot.Regs = .{};
    const ticks: u64 = 0;
    const view = try armed(&recorder, &floor, &regs, &ticks);
    try view.latch(place, 0x0200_0000);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), floor.latched);
    try std.testing.expectEqual(@as(usize, 0), (recorder.result(0) orelse return error.NotArmed).seen);
}

test "nothing watched leaves the run's wrap and retire listener as they were" {
    var recorder: Recorder = .{};
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    const image = try blankImage(&buffer);
    const ticks: u64 = 0;
    try std.testing.expect(recorder.arm(image, null, null, &ticks) == null);
    try std.testing.expect(recorder.listener(null) == null);
    try std.testing.expect(recorder.result(0) == null);
}

/// A listener the recorder stands in front of, counting what reached it.
const Behind = struct {
    buses: usize = 0,
    retired: usize = 0,
    regs: ?*const boot.Regs = null,

    fn wrap(self: *Behind) boot.Wrap {
        return .{ .context = self, .busFn = busFn, .sourceFn = sourceFn, .regsFn = regsFn };
    }

    fn busFn(context: *anyopaque, inner: bus.Bus) bus.Bus {
        const self: *Behind = @ptrCast(@alignCast(context));
        self.buses += 1;
        return inner;
    }

    fn sourceFn(_: *anyopaque, inner: ra8.chip.core.cpu.exception.source.Source) ra8.chip.core.cpu.exception.source.Source {
        return inner;
    }

    fn regsFn(context: *anyopaque, regs: *const boot.Regs) void {
        const self: *Behind = @ptrCast(@alignCast(context));
        self.regs = regs;
    }

    fn instruction(context: *anyopaque, _: u32) void {
        const self: *Behind = @ptrCast(@alignCast(context));
        self.retired += 1;
    }
};

test "the recorder chains over the listener behind it and the retire listener after it" {
    var recorder: Recorder = .{};
    var behind: Behind = .{};
    var floor: Floor = .{};
    var regs: boot.Regs = .{};
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    const image = try blankImage(&buffer);
    const ticks: u64 = 0;
    const wrap = recorder.arm(image, "0x220400A0", behind.wrap(), &ticks) orelse return error.NotArmed;
    const view = wrap.busFn(wrap.context, floor.view());
    if (wrap.regsFn) |lend| lend(wrap.context, &regs);
    try std.testing.expectEqual(@as(usize, 1), behind.buses);
    try std.testing.expect(behind.regs == &regs);
    const after: cpu.RetireListener = .{ .context = &behind, .instructionFn = Behind.instruction };
    const listener = recorder.listener(after) orelse return error.NoListener;
    try view.writeWord(place, 9);
    listener.instruction(0x0200_0020);
    try std.testing.expectEqual(@as(usize, 1), behind.retired);
    try std.testing.expectEqual(@as(usize, 1), recorder.watched.seen);
}
