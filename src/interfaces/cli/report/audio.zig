//! The audio part of the end-of-run report: SSIE on the way out, PDM on the
//! way in.
//!
//! There is no audio clock in the model, so what a run says about SSIE is the
//! handshake and the sample stream: whether the transmitter was actually on,
//! how many samples went out behind it, and what the transmit FIFO was still
//! holding when the run ended. PDM is the same question from the other side:
//! whether the samples a capture loop read were ever produced.
const Board = @import("../../../board/board.zig").Board;
const ssie = @import("ra8_chip").periph.ssie;
const Writer = @import("../report.zig").Writer;

/// One line per channel the firmware touched, plus the loud cases. A sample
/// staged with TEN clear is one dev counts as transmitted, a store past the
/// last FIFO stage is one dev never notices at all, and a store too narrow to
/// carry a sample is one dev turns into a part sample on the stream.
pub fn sections(board: *Board, out: Writer) !void {
    for (&board.audio.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "SSIE{d}: TEN={d} REN={d}, {d} sample(s) transmitted, last 0x{X:0>8}\n",
            .{
                index,
                @intFromBool(unit.transmitting()),
                @intFromBool(unit.ssicr & 1 != 0),
                unit.transmitted,
                unit.last,
            },
        );
        if (unit.staged() != 0) {
            try out.print(
                "SSIE{d}: {d} of {d} FIFO stage(s) still held with TEN clear, never shifted out\n",
                .{ index, unit.staged(), ssie.tx_depth },
            );
        }
        if (unit.dropped() != 0) {
            try out.print(
                "SSIE{d}: {d} sample(s) DROPPED on a full transmit FIFO\n",
                .{ index, unit.dropped() },
            );
        }
        if (unit.discarded() != 0) {
            try out.print(
                "SSIE{d}: {d} sample(s) thrown away by a FIFO reset before they went out\n",
                .{ index, unit.discarded() },
            );
        }
        if (unit.resetCount() != 0) {
            try out.print(
                "SSIE{d}: {d} software reset(s) via SSIFCR.SSIRST took the channel back to idle\n",
                .{ index, unit.resetCount() },
            );
        }
        if (unit.refused() != 0) {
            try out.print(
                "SSIE{d}: REFUSED {d} store(s) to SSIFTDR narrower than the register, no part sample was staged\n",
                .{ index, unit.refused() },
            );
        }
    }
}

/// One line per microphone channel the firmware touched. A starve is a read
/// dev would have served out of a FIFO it pins full, and an overrun is
/// microphone input dev never produces in the first place.
pub fn microphone(board: *Board, out: Writer) !void {
    for (&board.microphone.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "PDM{d}: run={d} read_en={d}, {d} sample(s) read, last 0x{X:0>5}, {d} waiting (synth tone)\n",
            .{
                index,
                @intFromBool(unit.running),
                @intFromBool(unit.read_enable),
                unit.read,
                unit.last,
                unit.filled,
            },
        );
        if (unit.starved != 0) {
            try out.print(
                "PDM{d}: {d} read(s) served nothing, the capture loop outran the microphone\n",
                .{ index, unit.starved },
            );
        }
        if (unit.overrun != 0) {
            try out.print(
                "PDM{d}: {d} sample(s) LOST to a full receive FIFO, the capture loop fell behind\n",
                .{ index, unit.overrun },
            );
        }
    }
}
