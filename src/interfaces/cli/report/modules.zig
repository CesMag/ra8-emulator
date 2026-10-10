//! The module-stop half of the end-of-run report. Split out of report.zig,
//! which was at the file-length limit.
//!
//! Two different runs drop the same accesses. One never cancels module stop,
//! so its reads give zero and its writes vanish on silicon: the loud line is
//! the bug the emulator used to hide. The other pokes a stopped window on
//! purpose to prove it is dead, then clears the bit and carries on. Only the
//! gate at the end of the run tells them apart, so that is what is asked
//! here rather than the counters alone.
const ckcr = @import("ra8_chip").periph.ckcr;
const ckdiv = @import("ra8_chip").periph.ckdiv;
const oscsf = @import("ra8_chip").periph.oscsf;
const mrms = @import("ra8_chip").periph.mrms;
const std = @import("std");

const Board = @import("../../../board/board.zig").Board;

const Writer = *std.Io.Writer;

/// The peripheral clock branches a run switched, and any switch PRCR ate.
/// A branch nobody asked for stays out of the report.
fn branches(board: *Board, out: Writer) !void {
    const unit = &board.branches;
    if (unit.quiet()) return;
    for (&unit.selects, 0..) |*one, index| {
        if (one.requests == 0 and one.switches == 0) continue;
        try out.print(
            "{s}: {d} switch request(s), {d} source change(s), source {d}\n",
            .{ ckcr.slots[index].name, one.requests, one.switches, one.sel },
        );
    }
    if (unit.dropped_locked != 0) {
        try out.print(
            "clock select: DROPPED {d} store(s) with PRCR.PRC0 locked\n",
            .{unit.dropped_locked},
        );
    }
}

/// The peripheral clock dividers a run programmed, and any divider store
/// that arrived while its branch was still running and so did not take.
fn ratios(board: *Board, out: Writer) !void {
    const unit = &board.ratios;
    if (unit.quiet()) return;
    for (&unit.dividers, 0..) |*one, index| {
        if (one.writes != 0) {
            try out.print(
                "{s}: divider code {d} ({d} store(s) inside the switch window)\n",
                .{ ckdiv.slots[index].name, one.value(), one.writes },
            );
        }
        if (one.ungated != 0) {
            try out.print(
                "{s}: {d} store(s) arrived with the branch running and did not take\n",
                .{ ckdiv.slots[index].name, one.ungated },
            );
        }
    }
    if (unit.dropped_locked != 0) {
        try out.print(
            "clock divider: DROPPED {d} store(s) with PRCR.PRC0 locked\n",
            .{unit.dropped_locked},
        );
    }
}

/// The clock sources a run started or stopped, and any store aimed at the
/// read-only flag register. A run that touched none of them says nothing.
fn oscillators(board: *Board, out: Writer) !void {
    const unit = &board.oscillators;
    if (unit.quiet()) return;
    if (unit.starts != 0 or unit.stops != 0) {
        try out.print(
            "clock sources: {d} start(s), {d} stop(s), OSCSF 0x{X:0>2}\n",
            .{ unit.starts, unit.stops, unit.flags() },
        );
    }
    if (unit.readonly_writes != 0) {
        try out.print(
            "clock sources: REFUSED {d} store(s) to OSCSF, which hardware owns\n",
            .{unit.readonly_writes},
        );
    }
    if (unit.dropped_locked != 0) {
        try out.print(
            "clock sources: DROPPED {d} store(s) with PRCR.PRC0 locked\n",
            .{unit.dropped_locked},
        );
    }
}

/// The 32.768 kHz sub-clock crystal: whether a run started it, the drive it
/// picked, and any drive change the part would have ignored.
fn subClock(board: *Board, out: Writer) !void {
    const unit = &board.subclk;
    if (unit.quiet()) return;
    try out.print(
        "sub-clock: {s}, drive {s}, {d} start(s)\n",
        .{ if (unit.running()) "running" else "stopped", unit.drive().name(), unit.starts },
    );
    if (unit.refused_running != 0) {
        try out.print(
            "sub-clock: REFUSED {d} SOMCR store(s), the crystal was already running\n",
            .{unit.refused_running},
        );
    }
    if (unit.dropped_locked != 0) {
        try out.print(
            "sub-clock: DROPPED {d} store(s) with PRCR.PRC0 locked\n",
            .{unit.dropped_locked},
        );
    }
}

/// The frequencies a run told the code-MRAM controller it was running at,
/// and any store the key byte turned away. The driver re-stores until the
/// readback matches, so a refusal here is a store that carried the wrong
/// key, never the retry loop doing its job.
fn memoryRates(board: *Board, out: Writer) !void {
    const unit = &board.memory_rates;
    if (unit.quiet()) return;
    try out.print(
        "MRMS: MRICLK {d} MHz, MRPCLK {d} MHz, prefetch buffer {s}\n",
        .{ unit.code.mhz, unit.extra.mhz, if (unit.prefetching()) "on" else "off" },
    );
    const refused = unit.code.refused + unit.extra.refused;
    if (refused != 0) {
        try out.print(
            "MRMS: DROPPED {d} frequency store(s) whose key byte was not 0x{X:0>2} or 0x{X:0>2}\n",
            .{ refused, mrms.key.mrcfreq >> 24, mrms.key.mrefreq >> 24 },
        );
    }
    if (unit.hot_changes != 0) {
        try out.print(
            "MRMS: {d} frequency store(s) taken with the prefetch buffer still on, clear MRCPFB first\n",
            .{unit.hot_changes},
        );
    }
    if (unit.early_enables != 0) {
        try out.print(
            "MRMS: {d} store(s) left the prefetch buffer on below the {d} MHz floor\n",
            .{ unit.early_enables, mrms.threshold_mhz },
        );
    }
}

pub fn section(board: *Board, out: Writer) !void {
    try branches(board, out);
    try ratios(board, out);
    try oscillators(board, out);
    try subClock(board, out);
    try memoryRates(board, out);
    if (board.modules.clean()) {
        try out.print("module stop: every peripheral the firmware touched was clocked\n", .{});
        return;
    }
    const verdict = board.modules.verdict();
    if (verdict.anyStopped()) {
        try out.print(
            "module stop: DROPPED {d} read(s) and {d} write(s) to stopped peripheral(s), last {s}, firmware forgot to cancel module stop\n",
            .{ verdict.stopped_reads, verdict.stopped_writes, verdict.last_stopped },
        );
    }
    if (verdict.anyProbed()) {
        try out.print(
            "module stop: {d} read(s) and {d} write(s) were dropped before the firmware ungated the block, last {s}\n",
            .{ verdict.probed_reads, verdict.probed_writes, verdict.last_probed },
        );
    }
}
