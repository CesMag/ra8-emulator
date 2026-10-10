//! Covers src/interfaces/cli/report/dma.zig: the totals the DMAC report line leads
//! with. The printing itself takes a file writer, so what is pinned here is
//! the tally behind it, which is where the counting rules live: a channel
//! that never moved is not busy, a channel left armed is, and the faults a
//! short transfer books are carried up so the loud line can be printed.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const report_dma = cli_app.report.dma;
const dmac = ra8.chip.periph.dmac;
const dma_bank = ra8.chip.periph.dma_bank;

/// A DMAC with no engine behind it. Nothing here asks it to transfer: the
/// tests set the counters a run would have left and ask what the report
/// would say about them.
const Fixture = struct {
    bank: dma_bank.Bank = dma_bank.Bank.init(),
    unit: dmac.Dmac = undefined,

    fn init(self: *Fixture) void {
        self.unit = dmac.Dmac.init(&self.bank);
    }

    /// One channel that took requests and moved bytes.
    fn moved(self: *Fixture, index: usize, requests: u32, units: u64) void {
        const channel = &self.unit.channels[index];
        channel.requests = requests;
        channel.units = units;
        channel.bytes = units;
        channel.completions = 1;
    }
};

test "a DMAC nobody touched has nothing to tally" {
    var fixture = Fixture{};
    fixture.init();
    const sum = report_dma.tally(&fixture.unit);
    try std.testing.expectEqual(@as(usize, 0), sum.busy);
    try std.testing.expect(!sum.stirred());
}

test "a channel that moved units is busy and its counts are carried up" {
    var fixture = Fixture{};
    fixture.init();
    fixture.moved(0, 8, 32);
    fixture.moved(3, 2, 8);
    const sum = report_dma.tally(&fixture.unit);
    try std.testing.expectEqual(@as(usize, 2), sum.busy);
    try std.testing.expectEqual(@as(u32, 10), sum.requests);
    try std.testing.expectEqual(@as(u64, 40), sum.units);
    try std.testing.expectEqual(@as(u64, 40), sum.bytes);
    try std.testing.expectEqual(@as(u32, 2), sum.completions);
    try std.testing.expect(sum.stirred());
}

test "a channel left armed counts as busy even having moved nothing" {
    var fixture = Fixture{};
    fixture.init();
    fixture.unit.channels[5].dmcnt |= dmac.field.dte;
    const sum = report_dma.tally(&fixture.unit);
    try std.testing.expectEqual(@as(usize, 1), sum.busy);
    try std.testing.expectEqual(@as(usize, 1), sum.armed);
    try std.testing.expectEqual(@as(u32, 0), sum.requests);
}

test "a finished channel is busy but no longer armed" {
    var fixture = Fixture{};
    fixture.init();
    fixture.moved(1, 4, 4);
    const sum = report_dma.tally(&fixture.unit);
    try std.testing.expectEqual(@as(usize, 1), sum.busy);
    try std.testing.expectEqual(@as(usize, 0), sum.armed);
}

test "short requests are carried up as faults, which is the loud line" {
    var fixture = Fixture{};
    fixture.init();
    fixture.moved(2, 3, 32);
    fixture.unit.channels[2].faults = 2;
    fixture.unit.channels[2].dmcnt |= dmac.field.dte;
    const sum = report_dma.tally(&fixture.unit);
    try std.testing.expectEqual(@as(u32, 2), sum.faults);
    try std.testing.expectEqual(@as(usize, 1), sum.armed);
}

test "refusals are the module's, not a channel's, so they stay off the tally" {
    var fixture = Fixture{};
    fixture.init();
    fixture.unit.request(0, false);
    try std.testing.expectEqual(@as(u32, 1), fixture.unit.refused);
    const sum = report_dma.tally(&fixture.unit);
    try std.testing.expectEqual(@as(usize, 0), sum.busy);
    try std.testing.expectEqual(@as(u32, 0), sum.requests);
}
