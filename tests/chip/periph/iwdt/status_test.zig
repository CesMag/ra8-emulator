//! IWDTSR: a read-only counter under two write-zero-to-clear flags.
const std = @import("std");
const ra8 = @import("ra8");

const status = ra8.chip.periph.iwdt.status;

test "a read packs the live counter under the latched flags" {
    try std.testing.expectEqual(@as(u16, 0x4123), status.value(0x0123, status.field.undff));
}

test "a read masks a counter wider than fourteen bits" {
    try std.testing.expectEqual(@as(u16, 0x3FFF), status.value(0xFFFF, 0));
}

test "a written zero clears a standing flag" {
    try std.testing.expectEqual(@as(u16, 0), status.ack(status.field.undff, 0));
}

test "a written one leaves a standing flag standing" {
    try std.testing.expectEqual(status.field.undff, status.ack(status.field.undff, status.field.flags));
}

test "a write cannot set a flag the hardware never raised" {
    try std.testing.expectEqual(@as(u16, 0), status.ack(0, status.field.flags));
}

test "clearing one flag leaves the other" {
    const held = status.field.flags;
    try std.testing.expectEqual(status.field.refef, status.ack(held, status.field.refef));
}

test "a write of one at a standing flag is refused" {
    try std.testing.expect(status.refused(status.field.refef, status.field.refef));
    try std.testing.expect(!status.refused(status.field.refef, 0));
}

test "the driver's own clear writes the counter bits back" {
    // ra8_iwdt_clear_status reads IWDTSR and writes it back with the flags
    // masked off, so the word it stores carries CNTVAL.
    const read_back = status.value(0x1234, status.field.undff);
    const written = read_back & ~status.field.flags;
    try std.testing.expect(status.carriesCount(written));
    try std.testing.expectEqual(@as(u16, 0), status.ack(status.field.undff, written));
}

test "a store with no counter bits carries none" {
    try std.testing.expect(!status.carriesCount(status.field.flags));
}

test "the fields sit where the header puts them" {
    try std.testing.expectEqual(@as(u16, 0x3FFF), status.field.cntval);
    try std.testing.expectEqual(@as(u16, 0x4000), status.field.undff);
    try std.testing.expectEqual(@as(u16, 0x8000), status.field.refef);
}
