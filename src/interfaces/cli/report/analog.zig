//! The analog part of the end-of-run report, both directions of it.
//!
//! DAC_B has no conversion-result readback on this part, so a headless run's
//! only window onto the channel is the code stream firmware wrote and whether
//! the channel was in a state that converts it: DACR0.DACEN set and
//! DACR0.DAOUTDIS clear.
const std = @import("std");

const Board = @import("ra8_board").board.Board;

const Writer = *std.Io.Writer;

/// One line per channel the firmware moved. The dark count is the loud case:
/// a code stored with DACEN clear latches but converts nothing, so an image
/// whose enable never took looks identical to a working one on dev, which
/// counts every store as an output.
pub fn sections(board: *Board, out: Writer) !void {
    for (&board.analog.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "DAC_B{d}: {d} output(s), last {d}, peak {d}, channel {s}\n",
            .{
                index,
                unit.outputs,
                unit.code(),
                unit.peak,
                if (unit.driving()) "driving" else if (unit.enabled()) "output disabled" else "disabled",
            },
        );
        if (unit.dark != 0) {
            try out.print(
                "DAC_B{d}: {d} code(s) written with DACEN clear, latched but not converted\n",
                .{ index, unit.dark },
            );
        }
        if (unit.blocked != 0) {
            try out.print(
                "DAC_B{d}: {d} code(s) written with DAOUTDIS set, latched but not driven\n",
                .{ index, unit.blocked },
            );
        }
        if (unit.above_data != 0) {
            try out.print(
                "DAC_B{d}: {d} store(s) landed in the reserved halfword above DADR, no code taken\n",
                .{ index, unit.above_data },
            );
        }
        if (unit.placement() != .right) {
            try out.print(
                "DAC_B{d}: DADR read {s}, per DACR1.DPSEL\n",
                .{ index, unit.placement().name() },
            );
        }
    }
}

/// The converter. A scan that ran is one line; a start the block refused and
/// a result firmware tried to write itself are separate, because each is a
/// bug a bench run would show and neither belongs folded into the traffic
/// that worked.
pub fn converter(board: *Board, out: Writer) !void {
    const unit = &board.adc;
    if (unit.quiet()) return;
    if (unit.scans != 0) {
        try out.print(
            "ADC_B: {d} scan(s), {d} channel(s) converted, last code {d} (0x{X:0>4})\n",
            .{ unit.scans, unit.converted, unit.last_code, unit.last_code },
        );
    }
    if (unit.refused_disabled != 0) {
        try out.print(
            "ADC_B: REFUSED {d} start(s) on a scan group ADSGER never enabled\n",
            .{unit.refused_disabled},
        );
    }
    if (unit.faked != 0) {
        try out.print(
            "ADC_B: REFUSED {d} store(s) into a result or status register\n",
            .{unit.faked},
        );
    }
    if (unit.empty != 0) {
        try out.print(
            "ADC_B: {d} scan(s) found no channel enrolled in the group\n",
            .{unit.empty},
        );
    }
    if (unit.unbacked != 0) {
        try out.print(
            "ADC_B: {d} converted channel(s) had no result register behind them\n",
            .{unit.unbacked},
        );
    }
    if (unit.stops != 0) {
        try out.print("ADC_B: {d} force-stop(s) through ADSTOPR\n", .{unit.stops});
    }
    if (unit.masked != 0) {
        try out.print(
            "ADC_B: {d} scan(s) raised nothing, ADINTCR clear\n",
            .{unit.masked},
        );
    }
}

/// The comparators. A headless run cannot show an analog level, so what this
/// says is what firmware actually drove: whether the channel is operating,
/// the polarity it presents its result through, the edge it asked to be told
/// about, and the reads that landed on a channel monitoring nothing.
pub fn comparators(board: *Board, out: Writer) !void {
    for (&board.comparators.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "ACMPHS{d}: {s}, {d} monitor read(s), output {s}, {s}\n",
            .{
                index,
                if (unit.operating()) "operating" else "off",
                unit.polls,
                if (unit.inverted()) "inverted" else "direct",
                unit.edge().name(),
            },
        );
        if (unit.dark_polls != 0) {
            try out.print(
                "ACMPHS{d}: {d} monitor read(s) with HCMPON clear, monitoring nothing\n",
                .{ index, unit.dark_polls },
            );
        }
        if (unit.refused != 0) {
            try out.print(
                "ACMPHS{d}: REFUSED {d} store(s) into CMPMON, which the comparator owns\n",
                .{ index, unit.refused },
            );
        }
    }
}
