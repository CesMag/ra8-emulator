//! Covers src/chip/periph/sci/error_latches.zig: the CSR error latches a driver has to
//! clear, which for now is the receive overrun.
const std = @import("std");
const ra8 = @import("ra8");
const sci_error = ra8.chip.periph.sci_error;
const status = ra8.chip.periph.sci_status;

test "a fresh channel is reporting nothing" {
    const errors = sci_error.Errors{};
    try std.testing.expectEqual(@as(u32, 0), errors.flags());
    try std.testing.expect(errors.quiet());
}

test "an overrun raises ORER and is counted" {
    var errors = sci_error.Errors{};
    errors.raiseOverrun();
    try std.testing.expect(errors.flags() & status.csr.orer != 0);
    try std.testing.expectEqual(@as(u32, 1), errors.overruns);
    try std.testing.expect(!errors.quiet());
}

test "a second overrun on a standing flag still counts" {
    var errors = sci_error.Errors{};
    errors.raiseOverrun();
    errors.raiseOverrun();
    try std.testing.expectEqual(@as(u32, 2), errors.overruns);
    try std.testing.expect(errors.flags() & status.csr.orer != 0);
}

test "only a store carrying ORERC puts the flag down" {
    var errors = sci_error.Errors{};
    errors.raiseOverrun();
    errors.clear(0);
    try std.testing.expect(errors.flags() & status.csr.orer != 0);
    errors.clear(0x0000_0010);
    try std.testing.expect(errors.flags() & status.csr.orer != 0);
    errors.clear(status.cfclr.orerc);
    try std.testing.expectEqual(@as(u32, 0), errors.flags());
}

test "ra8_sci_clear_errors' whole-mask store clears it" {
    var errors = sci_error.Errors{};
    errors.raiseOverrun();
    // k_ra8_sci_cfclr_default, the mask internal_clear_csr_flags writes.
    errors.clear(0x9D07_0010);
    try std.testing.expectEqual(@as(u32, 0), errors.flags());
}

test "the count survives the clear, so the run still reports what was lost" {
    var errors = sci_error.Errors{};
    errors.raiseOverrun();
    errors.clear(status.cfclr.orerc);
    try std.testing.expectEqual(@as(u32, 1), errors.overruns);
    try std.testing.expect(!errors.quiet());
}

test "a cleared flag rises again on the next overrun" {
    var errors = sci_error.Errors{};
    errors.raiseOverrun();
    errors.clear(status.cfclr.orerc);
    errors.raiseOverrun();
    try std.testing.expect(errors.flags() & status.csr.orer != 0);
    try std.testing.expectEqual(@as(u32, 2), errors.overruns);
}
