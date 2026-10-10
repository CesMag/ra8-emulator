//! The DMAC half of the end-of-run report. Split out of report.zig, which is
//! at the file-length limit, and kept next to the other report_*.zig files.
//!
//! The DMAC has counted its requests, units, bytes, completions, faults and
//! refusals since the model was written, and until now nothing printed any of
//! them: a run where channels were refused or cut short said so nowhere, and
//! the only way to see it was to write a probe. The DTC, DRW and PDM all have
//! a line here, so the DMAC gets one on the same shape.
//!
//! The two loud cases are worth reading closely. A REFUSED request moved
//! nothing at all and reads back to firmware as a channel that simply did not
//! transfer, which on dev passes silently because dev copies whatever the
//! module-start bit says. A SHORT request is the newer one: memory refused an
//! address partway through, so the units before it stayed, the counts went
//! back as they stood, and the channel is still armed over a transfer it
//! never finished.
const std = @import("std");

const Board = @import("../../../board/board.zig").Board;
const dmac = @import("ra8_chip").periph.dmac;

const Writer = *std.Io.Writer;

/// What the eight channels did between them, gathered before anything is
/// printed so the header can lead with the totals and the per-channel lines
/// can follow.
pub const Totals = struct {
    /// Channels that took a request or ended the run armed.
    busy: usize = 0,
    /// Channels still holding DMCNT.DTE up at the end of the run.
    armed: usize = 0,
    requests: u32 = 0,
    units: u64 = 0,
    bytes: u64 = 0,
    completions: u32 = 0,
    /// Requests memory cut short before the last of their units.
    faults: u32 = 0,

    /// Whether any channel has something to say. A module that was started
    /// and never used answers false here and still gets the header, because
    /// starting the DMAC and never transferring is itself worth reading.
    pub fn stirred(self: Totals) bool {
        return self.busy != 0;
    }
};

pub fn tally(unit: *const dmac.Dmac) Totals {
    var sum = Totals{};
    for (&unit.channels) |*channel| {
        if (channel.quiet()) continue;
        sum.busy += 1;
        if (channel.armed()) sum.armed += 1;
        sum.requests +%= channel.requests;
        sum.units += channel.units;
        sum.bytes += channel.bytes;
        sum.completions +%= channel.completions;
        sum.faults +%= channel.faults;
    }
    return sum;
}

pub fn section(board: *Board, out: Writer) !void {
    const unit = &board.dma;
    if (unit.quiet()) return;
    const sum = tally(unit);
    try out.print(
        "DMAC: {d} request(s), {d} unit(s) / {d} byte(s) moved, {d} transfer(s) finished, DMAST.DMST {s}\n",
        .{
            sum.requests,
            sum.units,
            sum.bytes,
            sum.completions,
            if (unit.started()) "set" else "CLEAR",
        },
    );
    try channels(unit, out);
    if (sum.faults != 0) {
        try out.print(
            "DMAC: {d} request(s) CUT SHORT by memory, the units before the refused address stayed and the counts went back\n",
            .{sum.faults},
        );
    }
    if (sum.armed != 0) {
        try out.print(
            "DMAC: {d} channel(s) ended the run with DMCNT.DTE up, so their transfer never finished\n",
            .{sum.armed},
        );
    }
    if (unit.refused == 0) return;
    try out.print(
        "DMAC: REFUSED {d} request(s), last because of {s} (the channel moved nothing)\n",
        .{ unit.refused, dmac.refusalName(unit.last_refusal.?) },
    );
}

/// One line per channel that was used, so a run only reports the channels the
/// firmware armed. The addresses are where the channel stands now, which is
/// where a short transfer stopped.
fn channels(unit: *const dmac.Dmac, out: Writer) !void {
    for (&unit.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        const shape = channel.plan();
        try out.print(
            "  ch{d}: {s}/{s}, {d} request(s), {d} unit(s) / {d} byte(s), {d} finished, DMSAR 0x{X:0>8}, DMDAR 0x{X:0>8}\n",
            .{
                index,
                @tagName(shape.mode),
                @tagName(shape.width),
                channel.requests,
                channel.units,
                channel.bytes,
                channel.completions,
                channel.dmsar,
                channel.dmdar,
            },
        );
        if (channel.faults != 0) {
            try out.print(
                "  ch{d}: {d} request(s) cut short, {d} unit(s) still owed on this block\n",
                .{ index, channel.faults, channel.pending },
            );
        }
    }
}
