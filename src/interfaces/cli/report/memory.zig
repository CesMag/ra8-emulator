//! The memory-controller part of the end-of-run report.
//!
//! On-chip SRAM is host memory here, so the only window onto the ECC path is
//! what the decoder self-test latched in SRAMESR and what it left in
//! SRAMEAR. The Arm cache window rides here too: it is the other thing
//! standing between the firmware and memory, and what it has to say is the
//! line size the firmware read and the maintenance it asked for.
const std = @import("std");

const Board = @import("../../../board/board.zig").Board;
const cache = @import("ra8_chip").periph.cache;

const Writer = *std.Io.Writer;

/// Quiet unless the run touched the ECC path. The refused store is the loud
/// case: SRAMESR is what the decoder found, so an image that wrote it was
/// claiming a caught fault it never injected.
pub fn sections(board: *Board, out: Writer) !void {
    try caches(board, out);
    const memory = &board.ecc;
    if (memory.quiet()) return;
    try out.print(
        "SRAM-ECC: {d} self-test latch(es), SRAMESR 0x{X:0>4}\n",
        .{ memory.latches, memory.esr },
    );
    if (memory.faked != 0) {
        try out.print(
            "SRAM-ECC: REFUSED {d} store(s) to SRAMESR, firmware cannot raise an ECC error flag itself\n",
            .{memory.faked},
        );
    }
    try protection(&memory.lock, out);
}

/// SRAMPRCR. Quiet unless a key was written or a guarded store happened,
/// and loud when one was turned away: a configuration write that never
/// landed is the kind of thing a driver does not notice until the bench.
fn protection(lock: *const @import("ra8_chip").periph.sram_lock.Lock, out: Writer) !void {
    if (lock.quiet()) return;
    try out.print(
        "SRAMPRCR: {s}, {d} key write(s), {d} guarded store(s) through\n",
        .{ if (lock.open()) "unlocked" else "locked", lock.accepted, lock.allowed },
    );
    if (lock.ignored != 0) {
        try out.print(
            "SRAMPRCR: {d} key write(s) IGNORED, the KW field was not 0xA5\n",
            .{lock.ignored},
        );
    }
    if (lock.blocked != 0) {
        try out.print(
            "SRAMPRCR: REFUSED {d} store(s) to a guarded register with the controller locked\n",
            .{lock.blocked},
        );
    }
}

/// The Arm cache window. The line size leads because it is the number every
/// by-address call multiplies by: against the zero CTR used to read, the
/// same clean did eight times the stores. A boundary is not a store, and the
/// wording says so: the PPB is read at the chunk boundary, so a run of
/// maintenance inside one chunk is counted once.
fn caches(board: *Board, out: Writer) !void {
    const unit = &board.caches;
    if (unit.quiet()) return;
    try out.print(
        "CACHE: D-cache line {d} bytes (CTR 0x{X:0>8}), I-cache {s}, D-cache {s}\n",
        .{
            unit.lineBytes(),
            unit.ctr,
            if (unit.icacheOn()) "on" else "off",
            if (unit.dcacheOn()) "on" else "off",
        },
    );
    for (0..cache.op_count) |index| {
        const which: cache.Op = @fromBackingInt(@intCast(index));
        const count = unit.count(which);
        if (count == 0) continue;
        try out.print("CACHE: {s} at {d} boundary(s)\n", .{ which.name(), count });
    }
    if (unit.walkDeclined() and unit.setWayAsked() != 0) {
        try out.print(
            "CACHE: the set/way walk found no geometry in CCSIDR and maintained nothing\n",
            .{},
        );
    }
    if (unit.refused != 0) {
        try out.print(
            "CACHE: REFUSED {d} store(s) to CTR or CCSIDR, both read-only on this core\n",
            .{unit.refused},
        );
    }
}
