//! The stop machine driven over a compiled program on the Zig core
//! (RA8EMU-673): every stop kind on real compiler output, with real calls,
//! a real stack frame and a counter in RAM, run through zig_drive.zig.
//!
//!   target(x):  ldr r1,=counter; ldr r2,[r1]; add r0,r2; str r0,[r1]; bx lr
//!   reset():    calls target(0..4) in a loop, then target(1) forever
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const memmap = ra8.chip.core.memmap;
const stop_machine = ra8.session.stop_machine;
const step_hook = ra8.session.step_hook;
const watch_table = ra8.session.watch_table;
const watch_bus = step_hook.watch_bus;
const zig_drive = step_hook.zig_drive;
const ZigCore = step_hook.zig_core.ZigCore;

const image = struct {
    const base: u32 = memmap.sram_base;
    const target: u32 = base + 0x08;
    const target_load: u32 = base + 0x0A;
    const target_add: u32 = base + 0x0C;
    const target_store: u32 = base + 0x0E;
    const target_return: u32 = base + 0x10;
    const reset: u32 = base + 0x18;
    const loop_call: u32 = base + 0x22;
    const after_loop_call: u32 = base + 0x26;
    const counter: u32 = base + 0x54;
    const stack: u32 = memmap.sram_base + 0x1F00;
    const budget: u64 = 400;
    const bytes = [_]u8{
        0x00, 0x00, 0x01, 0x22, 0x19, 0x00, 0x00, 0x22, 0x02, 0x49, 0x0a, 0x68, 0x10,
        0x44, 0x08, 0x60, 0x70, 0x47, 0x00, 0xbf, 0x54, 0x00, 0x00, 0x22, 0x10, 0xb5,
        0x00, 0x24, 0x05, 0x2c, 0x04, 0xd0, 0x20, 0x46, 0xff, 0xf7, 0xf1, 0xff, 0x01,
        0x34, 0xf8, 0xe7, 0x01, 0x20, 0xff, 0xf7, 0xec, 0xff, 0xfb, 0xe7, 0x70, 0x47,
    };
};

/// 8 KiB of SRAM holding the program, its counter and its stack.
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

const Fixture = struct {
    sram: Sram = .{},
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    cpu: Cpu = undefined,

    fn open(self: *Fixture) ZigCore {
        self.* = .{};
        @memcpy(self.sram.bytes[0..image.bytes.len], &image.bytes);
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = self.sram.view(), .driver = &self.driver };
        self.cpu = .{ .bus = self.watching.view() };
        self.cpu.regs.xpsr = ra8.chip.core.cpu.regs.xpsr_bits.thumb;
        const core: ZigCore = .{ .cpu = &self.cpu };
        core.setRegister(.sp, image.stack);
        return core;
    }

    /// Run from `from` until the machine stops it or the budget is spent.
    fn run(self: *Fixture, core: ZigCore, from: u32) zig_drive.Ended {
        core.setRegister(.pc, from);
        return zig_drive.runWatched(core, &self.machine, image.budget, &self.watching);
    }

    /// Carry on from wherever the last stop left the program counter.
    fn again(self: *Fixture, core: ZigCore) zig_drive.Ended {
        return self.run(core, core.register(.pc));
    }

    fn counter(self: *Fixture, core: ZigCore) !u32 {
        _ = self;
        return core.readWord(image.counter);
    }
};

test "continue stops on the third call into target, after two have stored" {
    var fixture: Fixture = undefined;
    const core = fixture.open();
    const id = try fixture.machine.breaks.add(.{ .address = image.target, .arrival = 3 });
    fixture.machine.proceed();
    try std.testing.expectEqual(id, fixture.run(core, image.reset).stop.breakpoint);
    try std.testing.expectEqual(image.target, core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0 + 1), try fixture.counter(core));
}

test "a break at an offset inside target stops on the store, unrun" {
    var fixture: Fixture = undefined;
    const core = fixture.open();
    _ = try fixture.machine.breaks.add(.{ .address = image.target_store });
    fixture.machine.proceed();
    try std.testing.expect(fixture.run(core, image.reset).stop == .breakpoint);
    try std.testing.expectEqual(image.target_store, core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0), try fixture.counter(core));
}

test "a step from a break moves one instruction and a second continue resumes past it" {
    var fixture: Fixture = undefined;
    const core = fixture.open();
    _ = try fixture.machine.breaks.add(.{ .address = image.target });
    fixture.machine.proceed();
    try std.testing.expect(fixture.run(core, image.reset).stop == .breakpoint);
    try std.testing.expectEqual(image.target, core.register(.pc));
    fixture.machine.step();
    try std.testing.expect(fixture.again(core).stop == .stepped);
    try std.testing.expectEqual(image.target_load, core.register(.pc));
    fixture.machine.proceed();
    try std.testing.expect(fixture.again(core).stop == .breakpoint);
    try std.testing.expectEqual(image.target, core.register(.pc));
    try std.testing.expectEqual(@as(u32, 2), fixture.machine.breaks.get(1).?.seen);
}

test "a step over the loop's call runs all of target and lands after the call" {
    var fixture: Fixture = undefined;
    const core = fixture.open();
    const id = try fixture.machine.breaks.add(.{ .address = image.loop_call });
    fixture.machine.proceed();
    try std.testing.expect(fixture.run(core, image.reset).stop == .breakpoint);
    try std.testing.expectEqual(image.loop_call, core.register(.pc));
    try fixture.machine.breaks.remove(id);
    fixture.machine.stepOver();
    try std.testing.expect(fixture.again(core).stop == .stepped);
    try std.testing.expectEqual(image.after_loop_call, core.register(.pc));
}

test "a step out of target returns to the instruction after its call" {
    var fixture: Fixture = undefined;
    const core = fixture.open();
    const id = try fixture.machine.breaks.add(.{ .address = image.target });
    fixture.machine.proceed();
    try std.testing.expect(fixture.run(core, image.reset).stop == .breakpoint);
    try fixture.machine.breaks.remove(id);
    fixture.machine.stepOut(core.register(.lr), core.register(.sp));
    _ = fixture.again(core);
    try std.testing.expectEqual(image.after_loop_call, core.register(.pc));
}

test "a halt request stops the run before its next instruction" {
    var fixture: Fixture = undefined;
    const core = fixture.open();
    fixture.machine.proceed();
    fixture.machine.requestHalt();
    try std.testing.expect(fixture.run(core, image.reset).stop == .halt_requested);
    try std.testing.expectEqual(image.reset + 2, core.register(.pc));
}

/// Where each watch kind on the counter leaves the program counter: after
/// the instruction whose access it was, never halfway through it.
fn expectWatchStop(kind: watch_table.Kind, access: watch_table.Access, after: u32) !void {
    var fixture: Fixture = undefined;
    const core = fixture.open();
    _ = try fixture.machine.watches.add(try watch_table.Watch.span(image.counter, 4, kind));
    fixture.machine.proceed();
    const hit = fixture.run(core, image.reset).stop.watchpoint;
    try std.testing.expectEqual(after, core.register(.pc));
    try std.testing.expectEqual(image.counter, hit.address);
    try std.testing.expectEqual(access, hit.access);
}

test "a read watch on the counter stops after target loads it" {
    try expectWatchStop(.read, .read, image.target_add);
}

test "a write watch on the counter stops after target stores it" {
    try expectWatchStop(.write, .write, image.target_return);
}

test "an access watch on the counter stops on the first touch, the load" {
    try expectWatchStop(.access, .read, image.target_add);
}
