//! Tests for src/chip/core/second_core.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.core.second_core;
const memmap = ra8.chip.core.memmap;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const Board = ra8.board.board.Board;
const sau = ra8.chip.periph.sau;
const mpu = ra8.chip.periph.mpu;
const scb = ra8.chip.periph.scb;
const nvic = ra8.chip.periph.nvic;

/// A thumb image is not needed to test the wiring: CPU1's own store
/// beside CPU0's, sharing its SRAM the way the Zig run lays them out.
/// Closed with `part`.
const Pair = struct {
    cpu0: Store,
    cpu1: Store,

    fn open(self: *Pair) !void {
        self.cpu0 = try Store.init(null);
        errdefer self.cpu0.deinit();
        self.cpu1 = try Store.init(&self.cpu0);
    }

    fn part(self: *Pair) void {
        self.cpu1.deinit();
        self.cpu0.deinit();
    }

    fn first(self: *Pair) Guest {
        return .{ .store = &self.cpu0 };
    }

    fn second(self: *Pair) Guest {
        return .{ .store = &self.cpu1 };
    }
};

test "what one core stores in shared SRAM the other core reads" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();

    try pair.second().writeWord(memmap.ns_sram_base + 0x100200, 0xB055_A55A);
    try std.testing.expectEqual(
        @as(u32, 0xB055_A55A),
        try pair.first().readWord(memmap.sram_base + 0x100200),
    );
}

test "a second core carries an SAU of its own, not the board's" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var cpu1: mod.Second = .{};

    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(&cpu1.partitions != &board.partitions);
}

test "a fresh second core's SAU is quiet, so it prints no line" {
    var cpu1 = mod.Second{};
    try std.testing.expect(cpu1.partitions.quiet());
}

test "one core's SAU map does not land in the other's table" {
    var mine = sau.Sau.init();
    var theirs = sau.Sau.init();

    // CPU0 programmes region 0 as Non-Secure Callable.
    _ = mine.observe(memmap.sau.rnr, 0);
    _ = mine.observe(memmap.sau.rbar, 0x0200_0000);
    _ = mine.observe(memmap.sau.rlar, 0x0207_FFE0 | sau.field.rlar_enable | sau.field.rlar_nsc);
    // CPU1 programmes its own region 0 as plain Non-Secure.
    _ = theirs.observe(memmap.sau.rnr, 0);
    _ = theirs.observe(memmap.sau.rbar, 0x5000_0000);
    _ = theirs.observe(memmap.sau.rlar, 0x5FFF_FFE0 | sau.field.rlar_enable);

    try std.testing.expectEqual(@as(u8, 1), mine.callable());
    try std.testing.expectEqual(@as(u8, 0), theirs.callable());
    try std.testing.expectEqual(@as(u32, 0x0200_0000), mine.table[0].base);
    try std.testing.expectEqual(@as(u32, 0x5000_0000), theirs.table[0].base);
}

test "a round is the chunk boundary" {
    try std.testing.expectEqual(ra8.chip.core.cadence.instructions, mod.limits.round);
}

test "a second core carries an MPU and guard of its own, not the board's" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var cpu1: mod.Second = .{};
    cpu1.regions = mpu.Mpu.init();
    cpu1.guard = ra8.chip.core.mpu_guard.Guard.init();

    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(&cpu1.regions != &board.regions);
    try std.testing.expect(&cpu1.guard != &board.guard);

    // The units CPU1's Zig core enforces are CPU1's table, never the board's.
    const units = mod.zig.Units.of(&cpu1);
    try std.testing.expect(units.regions == &cpu1.regions);
    try std.testing.expect(units.regions != &board.regions);
}

test "programming one core's MPU leaves the other's table alone" {
    var cpu0_regions = mpu.Mpu.init();
    const cpu1_regions = mpu.Mpu.init();

    // CPU0 programmes region 2 over the first SRAM page and enables.
    _ = cpu0_regions.observe(memmap.mpu.rnr, 2);
    _ = cpu0_regions.observe(memmap.mpu.rbar, memmap.sram_base);
    _ = cpu0_regions.observe(memmap.mpu.rlar, (memmap.sram_base + 0xFE0) | 1);
    _ = cpu0_regions.observe(memmap.mpu.ctrl, mpu.field.ctrl_enable);

    try std.testing.expectEqual(memmap.sram_base, cpu0_regions.table[2].base);
    try std.testing.expectEqual(@as(u8, 2), cpu0_regions.selected);
    try std.testing.expectEqual(@as(u32, 0), cpu1_regions.table[2].base);
    try std.testing.expectEqual(@as(u8, 0), cpu1_regions.selected);
    try std.testing.expectEqual(@as(u32, 0), cpu1_regions.ctrl);
}

test "a fresh second core's MPU is empty and off" {
    const cpu1 = mod.Second{};
    try std.testing.expectEqual(@as(u32, 0), cpu1.regions.ctrl);
    try std.testing.expect(cpu1.guard.unit == null);
}

test "each core reads its own VTOR, primed to its own vector base" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    const base: u32 = memmap.sram_base + 0x0010_0000;

    try mod.primeVectorTable(pair.second(), base);
    try std.testing.expectEqual(base, try pair.second().readWord(memmap.scb.vtor));
    try std.testing.expectEqual(@as(u32, 0), try pair.first().readWord(memmap.scb.vtor));
}

test "moving CPU0's vector table leaves CPU1's VTOR where it was" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    const base: u32 = memmap.sram_base + 0x0010_0000;
    try mod.primeVectorTable(pair.second(), base);

    try pair.first().writeWord(memmap.scb.vtor, memmap.sram_base);
    try std.testing.expectEqual(memmap.sram_base, try pair.first().readWord(memmap.scb.vtor));
    try std.testing.expectEqual(base, try pair.second().readWord(memmap.scb.vtor));
}

test "each core's AIRCR model keeps the PRIGROUP that core programmed" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var cpu1: mod.Second = .{};
    cpu1.control = scb.Scb.init();
    var cpu0_control = scb.Scb.init();
    try cpu0_control.prime(pair.first());
    try cpu1.control.prime(pair.second());

    const keyed: u32 = scb.key.write << scb.key.shift;
    try pair.second().writeWord(memmap.scb.aircr, keyed | (5 << 8));
    try std.testing.expect(!try cpu1.control.poll(pair.second()));
    try std.testing.expect(!try cpu0_control.poll(pair.first()));

    try std.testing.expectEqual(@as(u3, 5), cpu1.control.priorityGroup());
    try std.testing.expectEqual(@as(u3, 0), cpu0_control.priorityGroup());
    try std.testing.expectEqual(scb.key.status, try pair.first().readWord(memmap.scb.aircr));
}

test "a reset CPU1 asks for is counted on CPU1's model, not CPU0's" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var cpu1: mod.Second = .{};
    cpu1.control = scb.Scb.init();
    const cpu0_control = scb.Scb.init();
    try cpu1.control.prime(pair.second());

    const keyed: u32 = scb.key.write << scb.key.shift;
    try pair.second().writeWord(memmap.scb.aircr, keyed | scb.field.sysresetreq);
    try std.testing.expect(try cpu1.control.poll(pair.second()));
    try std.testing.expectEqual(@as(u32, 1), cpu1.control.requests);
    try std.testing.expectEqual(@as(u32, 0), cpu0_control.requests);
}

test "CCR, SHCSR and the fault status words are each core's own" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    const words = [_]u32{ memmap.scb.ccr, 0xE000_ED24, 0xE000_ED28, 0xE000_ED2C, 0xE000_ED34, 0xE000_ED38 };
    for (words, 0..) |address, i| {
        try pair.first().writeWord(address, 0x100 + @as(u32, @intCast(i)));
        try std.testing.expectEqual(@as(u32, 0), try pair.second().readWord(address));
    }
}
