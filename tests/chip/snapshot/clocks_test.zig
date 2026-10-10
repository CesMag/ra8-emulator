//! RA8EMU-670: the clock generation units saved with non-default state and
//! loaded into freshly wired units compare equal, keep the target's wiring,
//! and a missing or short section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const p = ra8.chip.periph;
const file = ra8.snapshot.file;
const clocks = ra8.chip.snapshot.clocks;

/// What the units point at. Two sets, so a load can be seen to keep its own.
const Live = struct {
    protection: p.prcr.Prcr = .{},
    branches: p.ckcr.Ckcr = undefined,
    oscillators: p.oscsf.Oscillators = undefined,
    voltage: p.vscr.Unit = undefined,
    brownout: p.voltage_hazard.Watch = undefined,
    modules: p.mstp.Mstp = .{},

    fn wire(self: *Live) void {
        self.branches = p.ckcr.Ckcr.init(&self.protection);
        self.oscillators = p.oscsf.Oscillators.init(&self.protection);
        self.voltage = p.vscr.Unit.init(&self.protection);
        self.brownout = p.voltage_hazard.Watch.init(&self.voltage);
    }
};

var first: Live = .{};
var second: Live = .{};

/// The Board's clock fields, under the Board's names.
const Stand = struct {
    protection: p.prcr.Prcr,
    branches: p.ckcr.Ckcr,
    ratios: p.ckdiv.Ckdiv,
    oscillators: p.oscsf.Oscillators,
    subclk: p.subclock.Unit,
    loco: p.subclock.loco.Unit,
    tree: p.sysclk.Tree,
    plls: p.pll.Unit,
    voltage: p.vscr.Unit,
    brownout: p.voltage_hazard.Watch,
    low_power: p.lpm.Unit,
    standby_cancel: p.lpm.dps.Dps,
    gpt_clock: p.gtclkcr.Unit,
    octa: p.octaclk.Octa,
    modules: p.mstp.Mstp,
};

fn fresh(live: *Live) Stand {
    live.wire();
    const prot = &live.protection;
    return .{
        .protection = .{},
        .branches = p.ckcr.Ckcr.init(prot),
        .ratios = p.ckdiv.Ckdiv.init(prot, &live.branches),
        .oscillators = p.oscsf.Oscillators.init(prot),
        .subclk = p.subclock.Unit.init(prot),
        .loco = p.subclock.loco.Unit.init(prot),
        .tree = p.sysclk.Tree.init(prot, &live.oscillators, &live.brownout),
        .plls = p.pll.Unit.init(prot, &live.oscillators),
        .voltage = p.vscr.Unit.init(prot),
        .brownout = p.voltage_hazard.Watch.init(&live.voltage),
        .low_power = p.lpm.Unit.init(prot),
        .standby_cancel = .{},
        .gpt_clock = p.gtclkcr.Unit.init(&live.modules),
        .octa = p.octaclk.Octa.init(&live.branches),
        .modules = .{},
    };
}

fn busy() Stand {
    var board = fresh(&first);
    board.protection.groups = 0x000B;
    board.protection.unlocks = 3;
    board.branches.selects[1].sel = 5;
    board.branches.selects[1].requested = true;
    board.ratios.dividers[2].code = 3;
    board.ratios.dropped_locked = 2;
    board.oscillators.shadow[0] = 0;
    board.oscillators.starts = 4;
    board.subclk.sosccr = 0;
    board.loco.lococr = 1;
    board.tree.divcr = 0x0102_0304;
    board.tree.cksel = 5;
    board.plls.pll1.ccr = 0x1F13;
    board.plls.moscwtcr = 9;
    board.voltage.vscm = true;
    board.brownout.lifts = 7;
    board.low_power.sbycr = 0x40;
    board.standby_cancel.bytes[3] = 0x81;
    board.gpt_clock.value = 1;
    board.octa.wedged = true;
    board.modules.regs[1] = 0x1234_5678;
    board.modules.masked_writes = 6;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try clocks.save(board, &list.writer);
}

test "every clock unit round-trips" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = fresh(&first);
    try clocks.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
}

test "a load keeps the target's wiring" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = fresh(&second);
    try clocks.load(&target, list.written());
    try std.testing.expectEqual(&second.protection, target.tree.protection);
    try std.testing.expectEqual(&second.brownout, target.tree.brownout);
    try std.testing.expectEqual(&second.voltage, target.brownout.voltage);
    try std.testing.expectEqual(&second.modules, target.gpt_clock.modules);
    try std.testing.expectEqual(&second.branches, target.octa.clocks);
    try std.testing.expectEqual(@as(u32, 0x0102_0304), target.tree.divcr);
    try std.testing.expect(target.octa.wedged);
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target = fresh(&first);
    target.tree.divcr = 9;
    try std.testing.expectError(error.Missing, clocks.load(&target, list.written()));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    const short = list.written()[0 .. list.written().len - 1];
    try std.testing.expect(std.meta.isError(clocks.load(&target, short)));
    try std.testing.expectEqual(@as(u32, 9), target.tree.divcr);
    try std.testing.expect(!target.octa.wedged);
}
