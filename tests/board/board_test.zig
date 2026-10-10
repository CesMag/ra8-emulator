//! Covers src/board/board.zig: the board wires every block onto one bus and
//! carries the chunk boundary, so this checks the wiring rather than the
//! models, which have their own test files.
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.board.Board;
const memmap = ra8.chip.core.memmap;
const scb = ra8.chip.periph.scb;
const icu = ra8.chip.periph.icu;
const reboot = ra8.chip.core.reboot;
const reset = ra8.chip.periph.reset;
const wdt = ra8.chip.periph.wdt;

/// A board with a bus but no CPU behind it. attach() needs an engine, so the
/// tests that only ask about the peripheral state build the board directly.
fn board() Board {
    return Board.init(std.testing.allocator);
}

/// The PPB words the boundary reads, standing in for the engine. AIRCR is
/// the one this file is about; the Arm cache window is read at the same
/// boundary, so the rest of the addresses are plain RAM here, which is what
/// the real mapping gives them.
const Ppb = struct {
    word: u32 = scb.key.status,
    slots: [16]Slot = @splat(Slot{}),

    const Slot = struct { at: u32 = 0, value: u32 = 0, used: bool = false };

    pub fn readWord(self: *Ppb, address: u32) !u32 {
        if (address == memmap.scb.aircr) return self.word;
        for (&self.slots) |*slot| {
            if (slot.used and slot.at == address) return slot.value;
        }
        return 0;
    }

    pub fn writeWord(self: *Ppb, address: u32, value: u32) !void {
        if (address == memmap.scb.aircr) {
            self.word = value;
            return;
        }
        for (&self.slots) |*slot| {
            if (slot.used and slot.at == address) {
                slot.value = value;
                return;
            }
        }
        for (&self.slots) |*slot| {
            if (slot.used) continue;
            slot.* = .{ .at = address, .value = value, .used = true };
            return;
        }
        return error.TooManyWords;
    }

    /// The store `ra8_reset_software_reset` makes.
    fn requestReset(self: *Ppb) void {
        self.word = (scb.key.write << scb.key.shift) | scb.field.sysresetreq;
    }
};

test "a fresh board reads back a power-on reset" {
    var unit = board();
    defer unit.deinit();
    try std.testing.expect(unit.causes.rstsr0 & reset.cause.porf != 0);
    try std.testing.expect(unit.causes.quiet());
}

test "a watchdog that asked for a reset hands it to the reset block" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    unit.watchdog.reset_requested = true;
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.latched(reset.cause.wdtrf));
    try std.testing.expect(unit.causes.rstsr0 & reset.cause.porf == 0);
    try std.testing.expectEqual(@as(u32, 1), unit.causes.requests);
    // Taken once: the request is cleared, so the next boundary does not
    // latch a second reboot for the same underflow.
    try std.testing.expect(!unit.watchdog.reset_requested);
    try unit.takeResetRequests(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.causes.requests);
}

test "a watchdog that never fired leaves the boot cause alone" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.causes.requests);
}

test "an underflow with RSTIRQS set reaches the reset block through the board" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    // Arm the counter the way the refresh sequence does, ask for a reset on
    // underflow, then run it dry a watchdog count at a time.
    unit.watchdog.wdtrcr = wdt.reset_control.rstirqs;
    unit.watchdog.armed = true;
    unit.watchdog.counter = 1;
    unit.watchdog.count();
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.quiet());
    unit.watchdog.count();
    try unit.takeResetRequests(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.watchdog.underflows);
    try std.testing.expect(unit.causes.latched(reset.cause.wdtrf));
}

test "a keyed SYSRESETREQ latches a software cause and asks for the reboot" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    var pending = reboot.Reboot{ .vector_base = 0x0200_0000 };
    unit.reboot = &pending;
    ppb.requestReset();
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.latched(reset.cause.swrf));
    try std.testing.expect(pending.requested);
    try std.testing.expectEqual(@as(u32, 1), unit.control.requests);
}

test "a watchdog reset asks for the reboot, not only the cause" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    var pending = reboot.Reboot{ .vector_base = 0x0200_0000 };
    unit.reboot = &pending;
    unit.watchdog.reset_requested = true;
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.latched(reset.cause.wdtrf));
    try std.testing.expect(pending.requested);
}

test "an IWDT reset asks for the reboot too" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    var pending = reboot.Reboot{ .vector_base = 0x0200_0000 };
    unit.reboot = &pending;
    unit.heartbeat.reset_requested = true;
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.latched(reset.cause.iwdtrf));
    try std.testing.expect(pending.requested);
}

test "a watchdog reset takes the interrupt latches down" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    var pending = reboot.Reboot{ .vector_base = 0x0200_0000 };
    unit.reboot = &pending;
    unit.events.links[3] = icu.field.ir | 7;
    unit.watchdog.reset_requested = true;
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(!unit.events.latched(3));
}

test "a keyless SYSRESETREQ reboots nothing" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    var pending = reboot.Reboot{ .vector_base = 0x0200_0000 };
    unit.reboot = &pending;
    ppb.word = scb.field.sysresetreq;
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(!unit.causes.latched(reset.cause.swrf));
    try std.testing.expect(!pending.requested);
    try std.testing.expectEqual(@as(u32, 1), unit.control.rejected);
}

test "a software reset takes the interrupt latches down" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    unit.events.links[3] = icu.field.ir | 7;
    try std.testing.expect(unit.events.latched(3));
    ppb.requestReset();
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(!unit.events.latched(3));
    // The link itself survives: this tree keeps peripheral state across a
    // reboot, and only the flag would have re-pended into a bare firmware.
    try std.testing.expectEqual(@as(u32, 7), unit.events.links[3] & icu.field.iels);
}

test "an AGT underflow is raised on the boundary that closes at its due time" {
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var unit = board();
    defer unit.deinit();
    try ra8.board.wiring.attachBlocks(&unit, memory);
    const agt = ra8.chip.periph.agt;
    const sched = ra8.chip.periph.agt_clock.sched;
    // 0x1100 counts at the AGT's PCLKB lands a few thousand ns past the
    // second whole boundary, wide enough that the floor does not round it.
    unit.interval.channels[0] = .{ .counter = 0x1100, .reload = 0xFFFF, .cr = agt.control.tstart };
    try sched.arm(&unit.interval, &unit.time.queue, 0);
    var boundary: usize = 0;
    while (unit.interval.channels[0].underflows == 0) : (boundary += 1) {
        try std.testing.expect(boundary < 8);
        const due = unit.time.queue.next().?;
        try unit.tick(memory, toDue(unit.ticker(), 50_000));
        // Nothing before the due time underflows, and the boundary that
        // does is the one whose end is that time, not the next whole one.
        // The count rather than `pending`: the boundary hands that to the
        // event path before it returns.
        if (unit.interval.channels[0].underflows != 0) try std.testing.expectEqual(due, unit.time.base.now());
        if (unit.interval.channels[0].underflows == 0) try std.testing.expect(unit.time.base.now() < due);
    }
    try std.testing.expectEqual(@as(usize, 3), boundary);
    try std.testing.expect(unit.time.base.now() % 50_000 != 0);
}

test "a WDT underflow lands on the boundary that closes at its due time, carry included" {
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var unit = board();
    defer unit.deinit();
    try ra8.board.wiring.attachBlocks(&unit, memory);
    // Three ticks from underflow, 20000 ns already carried toward the
    // first: due at 130000 ns, off the 50000 grid.
    unit.watchdog.wdtcr = wdt.controlWord(0, 0x1, 3, 3);
    unit.watchdog.wdtrcr = 0;
    unit.watchdog.armed = true;
    unit.watchdog.counter = 0;
    unit.watchdog.pace = wdt.clock.ticksPerCount(0x1) - 3;
    unit.watchdog.carry_ns = 20_000;
    try unit.watchdog.arm(&unit.time.queue, 0);
    try std.testing.expectEqual(@as(?u64, 130_000), unit.time.queue.next());
    var boundary: usize = 0;
    while (unit.watchdog.underflows == 0) : (boundary += 1) {
        try std.testing.expect(boundary < 8);
        try unit.tick(memory, toDue(unit.ticker(), 50_000));
        if (unit.watchdog.underflows == 0) try std.testing.expect(unit.time.base.now() < 130_000);
    }
    try std.testing.expectEqual(@as(usize, 3), boundary);
    try std.testing.expectEqual(@as(u64, 130_000), unit.time.base.now());
}

/// `width`, narrowed to end on the board's next queued event when that is
/// closer, as the run loop sizes a stretch.
fn toDue(tick: ra8.chip.core.tick.Tick, width: u32) u32 {
    const cycles = tick.cyclesToDue();
    if (cycles == 0 or cycles > std.math.maxInt(u32)) return width;
    const configured: ra8.chip.core.cadence.Cadence = .{ .per_boundary = width };
    return configured.narrowedTo(@intCast(cycles)).per_boundary;
}

/// A bare board with its blocks attached, ready for one boundary.
fn attached(unit: *Board, memory: ra8.chip.core.cpu.memory.guest.Guest) !void {
    try ra8.board.wiring.attachBlocks(unit, memory);
}

test "a boundary retunes the time base to CPU0's clock from the tree" {
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var unit = board();
    defer unit.deinit();
    try attached(&unit, memory);
    // The EK-RA8D2 quickstart: PLL1 at 1 GHz, CPU0 /2 and CPU1 /4.
    unit.plls.pll1 = .{ .ccr = 0xFA02, .ccr2 = 0x451 };
    unit.tree.cksel = @backingInt(ra8.chip.periph.sysclk.Source.pll1);
    unit.tree.divcr2 = 0x2021;
    unit.tree.selects = 1;
    try unit.tick(memory, 1_000);
    try std.testing.expectEqual(@as(u64, 500_000_000), unit.time.base.hz);
}

test "an untouched tree and one the rate table cannot price leave the time base alone" {
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var unit = board();
    defer unit.deinit();
    try attached(&unit, memory);
    try unit.tick(memory, 1_000);
    try std.testing.expectEqual(ra8.chip.periph.clocks.timebase.default_hz, unit.time.base.hz);
    unit.tree.cksel = @backingInt(ra8.chip.periph.sysclk.Source.loco);
    unit.tree.selects = 1;
    try unit.tick(memory, 1_000);
    try std.testing.expectEqual(ra8.chip.periph.clocks.timebase.default_hz, unit.time.base.hz);
}

test "a soak run notes a watchdog reset as its event at the virtual time it came" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    unit.run.soak.armed = true;
    unit.time.base.advance(2_500_000_000);
    unit.watchdog.reset_requested = true;
    try unit.takeResetRequests(&ppb);
    const event = unit.run.soak.event.?;
    try std.testing.expectEqual(@TypeOf(event.kind).watchdog_reset, event.kind);
    try std.testing.expectEqual(unit.time.base.now(), event.at_ns);
    try std.testing.expect(unit.causes.latched(reset.cause.wdtrf));
}

test "a run without --run-for keeps no soak event for a watchdog reset" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    unit.heartbeat.reset_requested = true;
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(!unit.run.soak.ended());
}
