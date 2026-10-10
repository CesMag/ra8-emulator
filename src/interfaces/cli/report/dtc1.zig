//! DTC1, CPU1's own transfer controller (HUM Rev 1.30 ch 18), in the
//! end-of-run report. It prints nothing while DTC1 is untouched, so a
//! single-core run, or a dual-core image whose CPU1 never programs it, reads
//! exactly as before.
const dtc = @import("ra8_chip").periph.dtc;

/// The headline, and the refusal line when CPU1 took an interrupt the DTC
/// would not run. Takes any writer so a test can read the lines back.
pub fn section(unit: *const dtc.Dtc, out: anytype) !void {
    if (unit.quiet()) return;
    try out.print(
        "DTC1 (CPU1): {d} activation(s), {d} unit(s) / {d} byte(s) moved, {d} descriptor(s) finished, DTCVBR 0x{X:0>8}\n",
        .{ unit.activations, unit.units, unit.bytes, unit.completions, unit.dtcvbr },
    );
    if (unit.suppressed != 0) {
        try out.print(
            "DTC1 (CPU1): {d} interrupt(s) kept from the core while a descriptor still had units left\n",
            .{unit.suppressed},
        );
    }
    if (unit.refused == 0) return;
    try out.print(
        "DTC1 (CPU1): REFUSED {d} activation(s), last because of {s} (the core took the interrupt)\n",
        .{ unit.refused, dtc.refusalName(unit.last_refusal.?) },
    );
}
