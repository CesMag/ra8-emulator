//! Blake3-128 post-state digest and divergence detection (Section 2.3 & 2.5).
//!
//! Complex slots (MMIO, PPB/SCS, Fabric, or components) verify state integrity
//! upon redo by re-executing the slot and checking the post-state digest against
//! the recorded digest.
//!
//! The digest is Blake3 truncated to 128 bits (16 bytes) over:
//! 1. Complete architectural core register state (`ArchState`).
//! 2. Serialized pre/post-state of touched sections (`micro_bytes`).
//!
//! A mismatch refuses visibly with the exact slot position, never continuing.
const std = @import("std");
const slot_mod = @import("window_slot.zig");
const fields = @import("ra8_board").snapshot.run.fields;

pub const Position = slot_mod.Position;
pub const Core = slot_mod.Core;
pub const ArchState = slot_mod.ArchState;

pub const Digest = [16]u8;

pub const DivergenceRefusal = struct {
    position: Position,
    expected_digest: Digest,
    actual_digest: Digest,
    core: Core = .cpu0,

    pub fn format(
        self: DivergenceRefusal,
        writer: anytype,
    ) !void {
        const exp_hex = std.fmt.bytesToHex(self.expected_digest, .lower);
        const act_hex = std.fmt.bytesToHex(self.actual_digest, .lower);
        try writer.print(
            "HistoryDivergence at round={d} phase={s} offset={d}: expected {s}, got {s}",
            .{
                self.position.r,
                @tagName(self.position.phase),
                self.position.o,
                &exp_hex,
                &act_hex,
            },
        );
    }
};

pub const RedoError = error{
    HistoryDivergence,
    RequiresReExecution,
    BarrierReached,
};

/// Computes the Blake3-128 post-state digest over core register state plus touched sections.
pub fn computeDigest(arch: *const ArchState, micro_bytes: []const u8) Digest {
    // Struct padding and inactive optional payloads are not guest state.
    var buffer: [256]u8 = undefined;
    var hashing = std.Io.Writer.Hashing(std.crypto.hash.Blake3).init(&buffer);
    fields.write(&hashing.writer, arch.*) catch unreachable;
    hashing.writer.writeAll(micro_bytes) catch unreachable;
    hashing.writer.flush() catch unreachable;
    var full: [32]u8 = undefined;
    hashing.hasher.final(&full);
    return full[0..16].*;
}

/// Verifies that re-executing a complex slot produced the exact post-state digest.
/// On mismatch, fills `out_refusal` with the exact slot position and returns `error.HistoryDivergence`.
pub fn verifyRedoDigest(
    expected: Digest,
    arch: *const ArchState,
    micro_bytes: []const u8,
    pos: Position,
    core: Core,
    out_refusal: ?*DivergenceRefusal,
) error{HistoryDivergence}!void {
    const actual = computeDigest(arch, micro_bytes);
    if (!std.mem.eql(u8, &actual, &expected)) {
        if (out_refusal) |refusal| {
            refusal.* = .{
                .position = pos,
                .expected_digest = expected,
                .actual_digest = actual,
                .core = core,
            };
        }
        return error.HistoryDivergence;
    }
}
