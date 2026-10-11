//! CPU1's own PendSV and SysTick on the Zig core (RA8EMU-612): what the
//! engine-side second_core tests checked before RA8EMU-607 removed CPU1's
//! old turn, now through second_zig_run.Driver on a Store, no engine.
const std = @import("std");
const ra8 = @import("ra8");
const second_core = ra8.chip.core.second.core;
const Driver = second_core.zig.run.Driver;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const Units = second_core.zig.Units;
const memmap = ra8.chip.core.memmap;
const nvic = ra8.chip.periph.nvic;
const systick_bank = ra8.chip.core.systick_bank;
const xpsr_bits = ra8.chip.core.cpu.regs.xpsr_bits;
const Board = ra8.board.board.Board;

const vectors: u32 = memmap.sram_base + 0x1000;
const spin: u32 = vectors + 0x200;
const handler: u32 = vectors + 0x300;
const masked: u32 = vectors + 0x340;
const stack: u32 = vectors + 0x800;

/// CPU0's store, CPU1's driver over a store that borrows it, and the board
/// both sit on. Built in place: the driver keeps pointers into itself.
const Pair = struct {
    board: Board,
    cpu0: Store,
    driver: Driver,

    fn open(self: *Pair, entry: u32) !void {
        self.board = Board.init(std.testing.allocator);
        errdefer self.board.deinit();
        self.cpu0 = try Store.init(null);
        errdefer self.cpu0.deinit();
        const driver = &self.driver;
        driver.second = .{ .state = .{ .vector_base = vectors } };
        driver.wiring = null;
        driver.ns_timebase = .{ .words = systick_bank.non_secure_words };
        driver.cycle_remainder = 0;
        driver.store = try Store.init(&self.cpu0);
        errdefer driver.close();
        const memory = self.cpu1();
        try memory.writeWord(vectors, stack);
        try memory.writeWord(vectors + 4, entry | 1);
        try memory.writeWord(vectors + 4 * nvic.pendsv, handler | 1);
        try memory.writeWord(vectors + 4 * (nvic.pendsv + 1), handler | 1);
        try halves(memory, spin, &.{0xE7FE});
        try halves(memory, handler, &.{0xE7FE});
        // cpsid i; cpsie i; b masked
        try halves(memory, masked, &.{ 0xB672, 0xB662, 0xE7FC });
        try driver.core.openOn(memory, Units.of(&driver.second), &self.board.bus);
    }

    fn close(self: *Pair) void {
        self.driver.close();
        self.cpu0.deinit();
        self.board.deinit();
    }

    fn cpu1(self: *Pair) Guest {
        return .{ .store = &self.driver.store.? };
    }

    fn cpu0Guest(self: *Pair) Guest {
        return .{ .store = &self.cpu0 };
    }

    /// The exception CPU1 is running, 0 in Thread mode.
    fn ipsr(self: *Pair) u32 {
        return self.driver.core.cpu.regs.xpsr & xpsr_bits.ipsr;
    }

    fn pc(self: *Pair) u32 {
        return self.driver.core.cpu.regs.pc & ~@as(u32, 1);
    }

    fn expectRunning(self: *Pair) !void {
        try std.testing.expectEqual(@as(?ra8.chip.core.fault.Fault, null), self.driver.second.state.fault);
    }
};

fn halves(memory: Guest, at: u32, program: []const u16) !void {
    for (program, 0..) |half, i| {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, half, .little);
        try memory.write(at + @as(u32, @intCast(2 * i)), &bytes);
    }
}

test "a PendSV pended on CPU1 is taken by CPU1's own NVIC" {
    var pair: Pair = undefined;
    try pair.open(spin);
    defer pair.close();

    try pair.cpu1().writeWord(memmap.scb.icsr, nvic.icsr_pendsvset);
    pair.driver.round(1000);
    try pair.expectRunning();
    try std.testing.expectEqual(handler, pair.pc());
    try std.testing.expectEqual(@as(u32, nvic.pendsv), pair.ipsr());
    // CPU0 saw none of it: nothing is pended in its own ICSR.
    try std.testing.expectEqual(@as(u32, 0), try pair.cpu0Guest().readWord(memmap.scb.icsr) & nvic.icsr_pendsvset);
}

test "a PendSV CPU1's own code stores ends CPU1's stretch" {
    var pair: Pair = undefined;
    try pair.open(spin);
    defer pair.close();
    // ldr r0, =ICSR; ldr r1, =PENDSVSET; str r1, [r0]; b .
    try halves(pair.cpu1(), spin, &.{ 0x4801, 0x4902, 0x6001, 0xE7FE });
    try pair.cpu1().writeWord(spin + 8, memmap.scb.icsr);
    try pair.cpu1().writeWord(spin + 12, nvic.icsr_pendsvset);

    pair.driver.round(1000);
    try pair.expectRunning();
    // PendSV was taken inside the turn, where the architecture puts it,
    // so CPU1 spent the rest of the turn in the handler.
    try std.testing.expectEqual(handler, pair.pc());
    try std.testing.expectEqual(@as(u32, nvic.pendsv), pair.ipsr());
    try std.testing.expectEqual(@as(u32, 0), try pair.cpu1().readWord(memmap.scb.icsr) & nvic.icsr_pendsvset);
}

test "a PendSV pended on CPU0 is never taken by CPU1" {
    var pair: Pair = undefined;
    try pair.open(spin);
    defer pair.close();

    try pair.cpu0Guest().writeWord(memmap.scb.icsr, nvic.icsr_pendsvset);
    pair.driver.round(1000);
    pair.driver.round(1000);
    try pair.expectRunning();
    try std.testing.expectEqual(spin, pair.pc());
    try std.testing.expectEqual(@as(u32, 0), pair.ipsr());
}

test "CPU1's SysTick counts on CPU1 and pends into CPU1's own NVIC" {
    var pair: Pair = undefined;
    try pair.open(spin);
    defer pair.close();
    const memory = pair.cpu1();
    try memory.writeWord(memmap.syst.rvr, 99);
    try memory.writeWord(memmap.syst.cvr, 0);
    try memory.writeWord(memmap.syst.csr, 0b111);

    pair.driver.round(1000);
    pair.driver.round(1000);
    try pair.expectRunning();
    try std.testing.expect(pair.driver.second.state.timebase.ticks > 0);
    try std.testing.expectEqual(handler, pair.pc());
    try std.testing.expectEqual(@as(u32, nvic.pendsv + 1), pair.ipsr());
    // CPU0's SysTick was never armed and nothing was pended on it.
    const cpu0 = pair.cpu0Guest();
    try std.testing.expectEqual(@as(u32, 0), try cpu0.readWord(memmap.syst.csr));
    try std.testing.expectEqual(@as(u32, 0), try cpu0.readWord(memmap.scb.icsr) & nvic.icsr_pendstset);
}

test "CPU0's SysTick never ticks CPU1's time base" {
    var pair: Pair = undefined;
    try pair.open(spin);
    defer pair.close();
    try pair.cpu0Guest().writeWord(memmap.syst.rvr, 99);
    try pair.cpu0Guest().writeWord(memmap.syst.csr, 0b111);

    pair.driver.round(1000);
    pair.driver.round(1000);
    try pair.expectRunning();
    try std.testing.expectEqual(@as(u64, 0), pair.driver.second.state.timebase.ticks);
    try std.testing.expectEqual(@as(u32, 0), try pair.cpu1().readWord(memmap.syst.csr));
    try std.testing.expectEqual(spin, pair.pc());
    try std.testing.expectEqual(@as(u32, 0), pair.ipsr());
}

test "a SysTick held by CPU1's mask is taken when the mask clears" {
    var pair: Pair = undefined;
    // Entered at the cpsie, so a turn of a multiple of three meets every
    // boundary with PRIMASK set: the shape of the module port's
    // __tx_ts_wait against CPU1's turn.
    try pair.open(masked + 2);
    defer pair.close();

    try pair.cpu1().writeWord(memmap.scb.icsr, nvic.icsr_pendstset);
    pair.driver.round(999);
    try pair.expectRunning();
    try std.testing.expectEqual(handler, pair.pc());
    try std.testing.expectEqual(@as(u32, nvic.pendsv + 1), pair.ipsr());
}
