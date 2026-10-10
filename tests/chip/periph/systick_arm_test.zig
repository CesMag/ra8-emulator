//! Tests for src/chip/periph/systick_arm.zig.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.chip.core.memmap;
const mod = ra8.chip.periph.systick_arm;
const clocks = ra8.chip.periph.clocks;

const Observed = mod.Observed;
const observe = mod.observe;
const csr_enable = clocks.csr_enable;
const csr_tickint = clocks.csr_tickint;

test "starting the counter ends the stretch, because the period it arms is narrower than it" {
    // The arming store the whole hook exists for: `ra8_systick_configure`
    // stages the reload with the counter stopped, then sets ENABLE, and the
    // stretch in flight was cut when nothing was armed.
    try std.testing.expectEqual(
        Observed.rearm,
        observe(memmap.syst.csr, csr_enable | csr_tickint, 0, 8_399),
    );
}

test "staging a reload with the counter stopped ends nothing" {
    // Period is zero either way, so nothing is swallowed and the driver can
    // stage the reload as freely as it likes.
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.rvr, 8_399, 0, 0));
}

test "starting a counter with a zero reload ends nothing" {
    // A zero reload never wraps, so the boundary cannot be narrowed by it.
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.csr, csr_enable, 0, 0));
}

test "re-arming a running counter with a new reload ends the stretch" {
    // The retune path: ra8_threadx_systick_retune reprogrammes SYST_RVR off
    // the live CPUCLK0 while the kernel tick is already running.
    try std.testing.expectEqual(
        Observed.rearm,
        observe(memmap.syst.rvr, 999_999, csr_enable | csr_tickint, 8_399),
    );
}

test "writing the same reload back leaves the period where it was" {
    try std.testing.expectEqual(
        Observed.none,
        observe(memmap.syst.rvr, 8_399, csr_enable, 8_399),
    );
}

test "the reload comparison is the 24-bit field, not the word" {
    // SYST_RVR is 24 bits; the bits above it are not the reload, so a store
    // that only changes them changes no period.
    try std.testing.expectEqual(
        Observed.none,
        observe(memmap.syst.rvr, 0xFF00_0000 | 8_399, csr_enable, 8_399),
    );
}

test "a control store that keeps the counter running ends nothing" {
    // Folding TICKINT in mid-run does not re-size anything, and the stretch
    // in flight was already cut from this period.
    try std.testing.expectEqual(
        Observed.none,
        observe(memmap.syst.csr, csr_enable | csr_tickint, csr_enable, 8_399),
    );
}

test "stopping the counter ends nothing, because a stretch cut from a period swallows none" {
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.csr, 0, csr_enable, 8_399));
}

test "a store anywhere else in the window ends nothing" {
    // SYST_CVR is written by the model at every boundary and by a driver
    // restarting a period, and neither changes how wide the period is.
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.cvr, 0, csr_enable, 8_399));
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.calib, 0, csr_enable, 8_399));
}
