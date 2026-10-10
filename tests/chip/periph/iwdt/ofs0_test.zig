//! The IWDT's view of OFS0: only the start bit.
const std = @import("std");
const ra8 = @import("ra8");

const ofs0 = ra8.chip.periph.iwdt_ofs0;

test "an erased option word leaves the IWDT stopped" {
    try std.testing.expect(!ofs0.autoStarts(ofs0.erased));
}

test "IWDTSTRT clear selects auto-start" {
    try std.testing.expect(ofs0.autoStarts(ofs0.erased & ~ofs0.field.strt));
}

test "only the start bit decides" {
    try std.testing.expect(ofs0.autoStarts(0x0000_0000));
    try std.testing.expect(!ofs0.autoStarts(ofs0.field.strt));
}
