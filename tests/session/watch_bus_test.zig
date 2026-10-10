//! Tests for src/session/watch_bus.zig: watchpoints and DWT data matches on
//! the Zig core stop on the recorded instruction.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const commands = ra8.session.commands;
const memmap = ra8.chip.core.memmap;
const session = ra8.session.session;
const stop_machine = ra8.session.stop_machine;
const step_hook = ra8.session.step_hook;
const watch_bus = step_hook.watch_bus;
const zig_drive = step_hook.zig_drive;
const zig_script = step_hook.zig_script;
const Session = ra8.session.api.Session;
const dwt = ra8.chip.periph.dwt;
const watch_table = ra8.session.watch_table;
const Store = ra8.chip.core.cpu.memory.store.Store;

/// The program tests/session/zig_script_test.zig uses: a loop at +0x18
/// calling a helper at +0x8 that adds r0 into the word at 0x22000054.
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
    \\watch 0x22000054
    \\run
    \\continue
    \\info registers
    \\delete 1
    \\rwatch 0x22000054
    \\continue
    \\quit
;

/// 8 KiB of SRAM at sram_base and the DWT's page, both plain memory.
const Memory = struct {
    sram: [0x2000]u8 = @splat(0),
    ppb: [0x1000]u8 = @splat(0),

    fn view(self: *Memory) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slice(self: *Memory, address: u32, len: usize) bus.Error![]u8 {
        if (address >= image.base and address - image.base + len <= self.sram.len) return self.sram[address - image.base ..][0..len];
        if (address >= dwt.base and address - dwt.base + len <= self.ppb.len) return self.ppb[address - dwt.base ..][0..len];
        return bus.Error.Unmapped;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slice(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slice(address, from.len), from);
    }
};

/// A Zig core on `memory` with the debugger listening.
const Rig = struct {
    memory: Memory = .{},
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    cpu: Cpu = undefined,

    fn wire(self: *Rig) void {
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = self.memory.view(), .driver = &self.driver };
        self.cpu = .{ .bus = self.watching.view() };
        self.cpu.regs.xpsr = ra8.chip.core.cpu.regs.xpsr_bits.thumb;
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
    var rig: Rig = .{};
    rig.wire();
    @memcpy(rig.memory.sram[0..image.bytes.len], &image.bytes);
    var live: Session = .{ .live = .{ .core = .{ .cpu = &rig.cpu }, .machine = &rig.machine, .budget = image.budget, .watch = &rig.watching } };
    var target: zig_script.ZigScript = .{ .session = &live };
    target.session.live.core.setRegister(.sp, image.stack);
    target.session.live.core.setRegister(.pc, image.reset & ~@as(u32, 1));
    try play(&target, into);
}

/// The recorded transcript this script must print on the Zig core.
const transcript =
    \\Watchpoint 1 (write) at 0x22000054
    \\Watchpoint 1: write of 4 at 0x22000054, 0x22000010: bx lr
    \\Watchpoint 1: write of 4 at 0x22000054, 0x22000010: bx lr
    \\r0  0x00000001  r1  0x22000054  r2  0x00000000  r3  0x00000000
    \\r12 0x00000000  sp  0x22001EF8  lr  0x22000027  pc  0x22000010
    \\Deleted watchpoint 1
    \\Watchpoint 2 (read) at 0x22000054
    \\Watchpoint 2: read of 4 at 0x22000054, 0x2200000C: add r0, r2
    \\
;

test "a write and a read watchpoint stop on the recorded instruction" {
    var got: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer got.deinit();
    try zig(&got.writer);
    try std.testing.expect(std.mem.indexOf(u8, got.written(), "Watchpoint 1: write") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.written(), "Watchpoint 2: read") != null);
    try std.testing.expectEqualStrings(transcript, got.written());
}

test "firmware that arms a DWT write comparator halts after the store on the Zig core" {
    var rig: Rig = .{};
    rig.wire();
    rig.machine.dwt.trcena = true;
    const code: u32 = image.base;
    const data: u32 = image.base + 0x1000;
    const function = dwt.match.data_write | (dwt.function_bits.action_debug << dwt.function_bits.action_shift) | (2 << dwt.function_bits.size_shift);
    // str r1,[r0,#0x20] (DWT_COMP0); str r2,[r0,#0x28] (DWT_FUNCTION0); str r4,[r3]; nop; nop.
    @memcpy(rig.memory.sram[0..10], &[_]u8{ 0x01, 0x62, 0x82, 0x62, 0x1C, 0x60, 0x00, 0xBF, 0x00, 0xBF });
    const core: step_hook.zig_core.ZigCore = .{ .cpu = &rig.cpu };
    core.setRegister(.pc, code);
    core.setRegister(.sp, image.stack);
    core.setRegister(.r0, dwt.base);
    core.setRegister(.r1, data);
    core.setRegister(.r2, function);
    core.setRegister(.r3, data);
    core.setRegister(.r4, 0x77);
    rig.machine.begin();
    const ended = zig_drive.runWatched(core, &rig.machine, 32, &rig.watching);
    try std.testing.expectEqual(@as(usize, 0), ended.stop.unit_watch);
    try std.testing.expectEqual(code + 6, core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x77), try core.readWord(data));
}

test "an instruction's own fetch is not an access" {
    var rig: Rig = .{};
    rig.wire();
    const code: u32 = image.base + 0x100;
    @memcpy(rig.memory.sram[0x100..0x108], &[_]u8{ 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF });
    _ = try rig.machine.addWatch(try ra8.session.watch_table.Watch.span(code, 4, .access));
    const core: step_hook.zig_core.ZigCore = .{ .cpu = &rig.cpu };
    core.setRegister(.pc, code);
    rig.machine.begin();
    try std.testing.expectEqual(.count, std.meta.activeTag(zig_drive.runWatched(core, &rig.machine, 3, &rig.watching)));
}

test "the core's fault latch passes through as a latch, not a store" {
    var under = @import("latch_bus.zig").Latches{};
    var watching = watch_bus.WatchBus{ .inner = under.view(), .driver = undefined };
    try watching.view().latch(0xE000_ED28, 1 << 25);
    try std.testing.expectEqual(@as(u32, 1 << 25), under.latched);
    try std.testing.expectEqual(@as(u32, 0), under.writes);
}

/// A board bus over the Zig core's store with the write-one-to-clear SCS
/// words wired, which is how zig_run builds it, so a lost latch shows up here.
const Board = struct {
    store: Store = undefined,
    periph: ra8.chip.periph.registry.Bus = undefined,
    clears: ra8.chip.core.cpu.board_bus.fault_clear.Clears = undefined,
    board: ra8.chip.core.cpu.board_bus.BoardBus = undefined,

    fn open(self: *Board) !void {
        self.store = try Store.init(null);
        self.periph = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
        self.clears = ra8.chip.core.cpu.board_bus.fault_clear.Clears.init();
        self.board = .{ .memory = .{ .store = .{ .store = &self.store } }, .periph = &self.periph, .scs = .{ .clears = &self.clears } };
    }

    fn close(self: *Board) void {
        self.periph.deinit();
        self.store.deinit();
    }

    fn put(self: *Board, address: u32, value: u32) void {
        std.mem.writeInt(u32, self.store.span(address, 4).?[0..4], value, .little);
    }
};

test "a trapped divide by zero reads DIVBYZERO back at CFSR through the watched board bus" {
    var rig: Board = .{};
    try rig.open();
    defer rig.close();
    var machine: stop_machine.Machine = .{};
    var driver: step_hook.Driver = .{ .machine = &machine };
    var watching: watch_bus.WatchBus = .{ .inner = rig.board.view(), .driver = &driver };
    const base = memmap.sram_base;
    const code = base + 0x100;
    const usage = base + 0x1C0;
    rig.put(base, base + 0x1F00);
    rig.put(base + 4, code | 1);
    rig.put(base + 6 * 4, usage | 1);
    rig.put(code, 0xF2F1_FB90); // sdiv r2, r0, r1
    rig.put(usage, 0xBF00_6823); // ldr r3, [r4]; nop
    var cpu: Cpu = .{ .bus = watching.view() };
    try cpu.reset(base);
    rig.put(memmap.scb.ccr, 1 << 4); // DIV_0_TRP
    rig.put(memmap.scb.shcsr, 1 << 18); // USGFAULTENA
    cpu.regs.low[0] = 100;
    cpu.regs.low[1] = 0;
    cpu.regs.low[4] = memmap.scb.cfsr;
    machine.begin();
    watching.arm(code, 4);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage, cpu.regs.pc);
    watching.arm(usage, 2);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 1 << 25), cpu.regs.low[3] & (1 << 25));
    try std.testing.expectEqual(@as(u32, 1 << 25), rig.board.faults().cfsr);
}

test "a quiet bus listens only to the PPB, and a store there ends the stretch" {
    var memory: Memory = .{};
    var machine: stop_machine.Machine = .{};
    machine.begin();
    var driver: step_hook.Driver = .{ .machine = &machine };
    var listening: watch_bus.WatchBus = .{ .inner = memory.view(), .driver = &driver };
    _ = try machine.addWatch(try watch_table.Watch.span(image.base + 0x100, 4, .write));
    listening.arm(0, 0);
    listening.quiet = true;
    const view = listening.view();
    try view.write(image.base + 0x100, &[_]u8{ 1, 0, 0, 0 });
    try std.testing.expect(machine.watch_pending == null);
    try std.testing.expect(!listening.ppb.seen);
    try view.write(dwt.base + 4, &[_]u8{ 0, 0, 0, 0 });
    try std.testing.expect(listening.ppb.seen);
    listening.quiet = false;
    try view.write(image.base + 0x100, &[_]u8{ 2, 0, 0, 0 });
    try std.testing.expect(machine.watch_pending != null);
}
