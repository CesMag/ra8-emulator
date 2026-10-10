//! RA8EMU-671: the security and system control units saved with
//! non-default state and loaded into fresh units compare equal, keep the
//! target's wiring, refuse a region select past its table, and a missing
//! or short section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const p = ra8.chip.periph;
const mpu_guard = ra8.chip.core.mpu_guard;
const file = ra8.snapshot.file;
const security = ra8.chip.snapshot.security;

/// What the units point at. Two sets, so a load can be seen to keep its own.
const Live = struct {
    protection: p.prcr.Prcr = .{},
    sram: p.cpscu.sram.Unit = .{},
    watchdog: bool = false,
    heartbeat: bool = false,
};

var first: Live = .{};
var second: Live = .{};

/// The Board's security fields, under the Board's names.
const Stand = struct {
    attribution: p.pscu.Unit,
    transfer_attribution: p.dtc.attribution.Unit,
    chip_attribution: p.cpscu.Unit,
    sram_attribution: p.cpscu.sram.Unit,
    memory_monitors: p.pscu.samon.Unit,
    idau: p.sau.idau.Map,
    second_core: p.cpu_ctrl.CpuCtrl,
    causes: p.reset.Reset,
    control: p.scb.Scb,
    clears: p.fault_status.clear.Clears,
    caches: p.cache.Cache,
    regions: p.mpu.Mpu,
    regions_ns: p.mpu.Mpu,
    guard: mpu_guard.Guard,
    partitions: p.sau.Sau,
};

fn fresh(live: *Live, ra8p1: bool) Stand {
    var board: Stand = .{
        .attribution = .{},
        .transfer_attribution = p.dtc.attribution.Unit.init(&live.protection),
        .chip_attribution = p.cpscu.Unit.init(&live.protection),
        .sram_attribution = .{},
        .memory_monitors = .{},
        .idau = p.sau.idau.Map.forPart(&live.sram, ra8p1),
        .second_core = .{},
        .causes = p.reset.Reset.init(),
        .control = p.scb.Scb.init(),
        .clears = p.fault_status.clear.Clears.init(),
        .caches = p.cache.Cache.init(),
        .regions = p.mpu.Mpu.init(),
        .regions_ns = p.mpu.Mpu.init(),
        .guard = mpu_guard.Guard.init(),
        .partitions = p.sau.Sau.init(),
    };
    board.causes.watchWatchdogs(&live.protection, &live.watchdog, &live.heartbeat);
    return board;
}

fn busy() Stand {
    var board = fresh(&first, false);
    board.attribution.words[1] = 0x00F0_0F00;
    board.transfer_attribution.word = 0;
    board.chip_attribution.words[2] = 0x1234;
    board.sram_attribution.sabar[1] = 0x55;
    board.memory_monitors.cms = 0x1A3;
    board.idau.code_secure = 0x0010_0000;
    board.second_core.initvtor = 0x0200_0400;
    board.second_core.act = true;
    board.causes.pending = .software;
    board.causes.requests = 2;
    board.causes.masks.dropped_locked = 3;
    board.control.writes = 4;
    board.clears.hfsr.dirty = true;
    board.caches.selected = 1;
    board.caches.enables = 5;
    board.regions.table[3] = .{ .base = 0x2000_0000, .limit = 0x2000_FFFF, .enabled = true, .rbar = 0x2000_0001, .rlar = 0x2000_FFE1 };
    board.regions.selected = 3;
    board.regions_ns.ctrl = 5;
    board.guard.latch.pending = .{ .pc = 0x100, .address = 0x2000_0010 };
    board.guard.latch.violations = 7;
    board.partitions.table[1].callable = true;
    board.partitions.selected = 1;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try security.save(board, &list.writer);
}

test "every security unit round-trips" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = fresh(&first, false);
    try security.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
}

test "a load keeps the target's wiring" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = fresh(&second, true);
    const banks = target.idau.banks;
    try security.load(&target, list.written());
    try std.testing.expectEqual(&second.sram, target.idau.sram.?);
    try std.testing.expectEqual(banks, target.idau.banks);
    try std.testing.expectEqual(&second.protection, target.chip_attribution.protection.?);
    try std.testing.expectEqual(&second.watchdog, target.causes.masks.watchdog_armed);
    try std.testing.expectEqual(@as(u32, 3), target.causes.masks.dropped_locked);
    try std.testing.expectEqual(@as(?u32, 0x0010_0000), target.idau.code_secure);
}

test "a region select past the table is refused" {
    var board = busy();
    board.partitions.selected = @intCast(board.partitions.table.len);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = fresh(&first, false);
    try std.testing.expectError(error.BadValue, security.load(&target, list.written()));
    try std.testing.expectEqual(@as(u8, 0), target.partitions.selected);
    try std.testing.expectEqual(@as(u32, 0), target.causes.requests);
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target = fresh(&first, false);
    try std.testing.expectError(error.Missing, security.load(&target, list.written()));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    try std.testing.expect(std.meta.isError(security.load(&target, list.written()[0 .. list.written().len - 1])));
    try std.testing.expectEqual(@as(u32, 0), target.second_core.initvtor);
    try std.testing.expectEqual(@as(u64, 0), target.guard.latch.violations);
}
