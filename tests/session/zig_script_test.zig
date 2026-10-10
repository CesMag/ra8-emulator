//! Tests for src/session/zig_script.zig: one script on the Zig core prints
//! its recorded transcript.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const commands = ra8.core.commands;
const memmap = ra8.core.memmap;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const Session = ra8.core.session_api.Session;
const step_hook = ra8.core.step_hook;
const zig_script = step_hook.zig_script;

const image = struct {
    const base: u32 = memmap.sram_base;
    const reset: u32 = base + 0x18;
    const stack: u32 = memmap.sram_base + 0x1F00;
    const budget: usize = 400;
    const bytes = [_]u8{
        0x00, 0x00, 0x01, 0x22, 0x19, 0x00, 0x00, 0x22, 0x02, 0x49, 0x0a, 0x68, 0x10,
        0x44, 0x08, 0x60, 0x70, 0x47, 0x00, 0xbf, 0x54, 0x00, 0x00, 0x22, 0x10, 0xb5,
        0x00, 0x24, 0x05, 0x2c, 0x04, 0xd0, 0x20, 0x46, 0xff, 0xf7, 0xf1, 0xff, 0x01,
        0x34, 0xf8, 0xe7, 0x01, 0x20, 0xff, 0xf7, 0xec, 0xff, 0xfb, 0xe7, 0x70, 0x47,
    };
};

const script =
    \\break 0x22000008 3
    \\run
    \\info registers
    \\x 0x22000054 2
    \\p 0x22000054
    \\step
    \\step
    \\next
    \\finish
    \\bt
    \\tbreak 0x22000022
    \\continue
    \\continue
    \\delete 1
    \\break nowhere
    \\delete 7
    \\continue
    \\quit
    \\step
;

/// 8 KiB of SRAM at sram_base.
const Sram = struct {
    bytes: [0x2000]u8 = @splat(0),

    fn view(self: *Sram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slice(self: *Sram, address: u32, len: usize) bus.Error![]u8 {
        if (address < image.base or address - image.base + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[address - image.base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Sram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slice(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Sram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slice(address, from.len), from);
    }
};

fn play(target: anytype, into: *std.Io.Writer) !void {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        const command = (try commands.parse(line)) orelse continue;
        if (try target.apply(command, into) == .quit) return;
    }
}

fn zig(into: *std.Io.Writer) !void {
    var memory: Sram = .{};
    @memcpy(memory.bytes[0..image.bytes.len], &image.bytes);
    var cpu: Cpu = .{ .bus = memory.view() };
    cpu.regs.xpsr = ra8.core.cpu.regs.xpsr_bits.thumb;
    var machine: stop_machine.Machine = .{};
    var live: Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = image.budget } };
    var target: zig_script.ZigScript = .{ .session = &live };
    target.session.live.core.setRegister(.sp, image.stack);
    target.session.live.core.setRegister(.pc, image.reset & ~@as(u32, 1));
    try play(&target, into);
}

/// The recorded transcript this script must print on the Zig core.
const transcript =
    \\Breakpoint 1 at 0x22000008, arrival 3
    \\Breakpoint 1, 0x22000008: ldr r1, [pc, #8]
    \\r0  0x00000002  r1  0x22000054  r2  0x00000000  r3  0x00000000
    \\r12 0x00000000  sp  0x22001EF8  lr  0x22000027  pc  0x22000008
    \\0x22000054: 0x00000001 0x00000000
    \\0x22000054 = 0x00000001 (1)
    \\0x2200000A: ldr r2, [r1]
    \\0x2200000C: add r0, r2
    \\0x2200000E: str r0, [r1]
    \\0x22000026: adds r4, #1
    \\#0 0x22000026
    \\#1 0x22000026
    \\Temporary breakpoint 2 at 0x22000022
    \\Temporary breakpoint 2, 0x22000022: bl #0x22000008
    \\Breakpoint 1, 0x22000008: ldr r1, [pc, #8]
    \\Deleted breakpoint 1
    \\error: NoSymbols
    \\error: NoSuchBreak
    \\Budget of 400 instructions spent at 0x2200000C
    \\
;

test "a script prints its recorded transcript on the Zig core" {
    var got: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer got.deinit();
    try zig(&got.writer);
    try std.testing.expect(std.mem.indexOf(u8, got.written(), "Breakpoint 1, 0x22000008") != null);
    try std.testing.expectEqualStrings(transcript, got.written());
}

test "a command the Zig core does not carry out yet says so" {
    var memory: Sram = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    var machine: stop_machine.Machine = .{};
    var live: Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 } };
    var target: zig_script.ZigScript = .{ .session = &live };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try target.apply(.{ .halting = true }, &out.writer);
    try std.testing.expectEqualStrings("error: Unsupported\n", out.written());
}

test "core 1 with no second core says so and the session carries on" {
    var memory: Sram = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    var machine: stop_machine.Machine = .{};
    var live: Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 } };
    var target: zig_script.ZigScript = .{ .session = &live };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(.more, try target.apply(.{ .core = 1 }, &out.writer));
    try std.testing.expectEqualStrings("error: CoreNotAttached\n", out.written());
}

test "plug and unplug wire a part in and out through the board mid-script" {
    var memory: Sram = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    var machine: stop_machine.Machine = .{};
    var live: Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 } };
    var target: zig_script.ZigScript = .{ .session = &live };
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var plugs = ra8.board.session_plug.Plugs.init(&board, arena.allocator());
    target.session.attachPlugs(plugs.hook());
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const registry = &board.wire.controller.devices;
    _ = try target.apply((try commands.parse("plug max17048@i2c:riic@0x36")).?, &out.writer);
    try std.testing.expect(registry.answering(0x36) != null);
    _ = try target.apply((try commands.parse("unplug i2c:riic@0x36")).?, &out.writer);
    try std.testing.expect(registry.answering(0x36) == null);
    _ = try target.apply((try commands.parse("unplug i2c:riic@0x36")).?, &out.writer);
    _ = try target.apply((try commands.parse("plug @uart:sci3")).?, &out.writer);
    const want =
        \\Plugged max17048 into i2c:riic@0x36
        \\Unplugged i2c:riic@0x36
        \\error: NothingFitted
        \\error: MissingPart
        \\
    ;
    try std.testing.expectEqualStrings(want, out.written());
}

const FakeWall = struct {
    at: u64 = 0,

    fn clock(self: *FakeWall) ra8.board.run.pacer.Clock {
        return .{ .ctx = self, .nowFn = now, .sleepFn = sleep };
    }

    fn now(ctx: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(ctx));
        return self.at;
    }

    fn sleep(ctx: *anyopaque, ns: u64) void {
        const self: *FakeWall = @ptrCast(@alignCast(ctx));
        self.at += ns;
    }
};

test "speed moves the board's pacer mid-script and refuses a bad factor" {
    var memory: Sram = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    var machine: stop_machine.Machine = .{};
    var live: Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 } };
    var target: zig_script.ZigScript = .{ .session = &live };
    var time = ra8.periph.clocks.Time{};
    time.base.advance(1000);
    var wall = FakeWall{};
    var paced: ?ra8.board.run.pacing.Pacing = null;
    var speed: ra8.board.board_speed.BoardSpeed = .{ .time = &time, .paced = &paced, .clock = wall.clock() };
    target.session.speed = speed.hook();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const before = time.base.now();
    _ = try target.apply((try commands.parse("speed 0.25")).?, &out.writer);
    try std.testing.expectEqual(@as(u64, 250), paced.?.pacer.speed_milli);
    _ = try target.apply((try commands.parse("speed 5")).?, &out.writer);
    try std.testing.expectEqual(@as(u64, 5000), paced.?.pacer.speed_milli);
    _ = try target.apply((try commands.parse("speed 0")).?, &out.writer);
    try std.testing.expectEqual(@as(u64, 5000), paced.?.pacer.speed_milli);
    _ = try target.apply((try commands.parse("speed max")).?, &out.writer);
    try std.testing.expect(paced == null);
    try std.testing.expectEqual(before, time.base.now());
    const want =
        \\Speed 0.25x
        \\Speed 5x
        \\error: InvalidSpeed
        \\Speed max
        \\
    ;
    try std.testing.expectEqualStrings(want, out.written());
}
