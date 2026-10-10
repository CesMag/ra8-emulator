const std = @import("std");
const ra8 = @import("ra8");
const errors = ra8.chip.periph.canfd_error;

test "a fresh channel has no error flags standing" {
    const unit = errors.Errors{};
    try std.testing.expectEqual(@as(u32, 0), unit.read());
    try std.testing.expect(unit.quiet());
}

test "a store cannot raise a flag the controller never saw" {
    var unit = errors.Errors{};
    unit.store(0, 4, errors.mask.flags);
    try std.testing.expectEqual(@as(u32, 0), unit.read());
    try std.testing.expectEqual(@as(u32, 1), unit.invented);
}

test "a zero at a standing flag clears it" {
    var unit = errors.Errors{};
    unit.flags = 0x0003;
    unit.store(0, 4, 0x0002);
    try std.testing.expectEqual(@as(u32, 0x0002), unit.read());
}

test "the driver's clear of one flag leaves the others alone" {
    var unit = errors.Errors{};
    unit.flags = 0x0015;
    // ra8_canfd_clear_status writes ERFL & ~mask, here clearing bit 2.
    unit.store(0, 4, unit.read() & ~@as(u32, 0x0004));
    try std.testing.expectEqual(@as(u32, 0x0011), unit.read());
    try std.testing.expectEqual(@as(u32, 0), unit.invented);
}

test "the dispatch's write of zero clears every flag" {
    var unit = errors.Errors{};
    unit.flags = errors.mask.flags;
    unit.store(0, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read());
}

test "a byte store only touches the flags in its own byte" {
    var unit = errors.Errors{};
    unit.flags = 0x7FFF;
    unit.store(0, 1, 0);
    try std.testing.expectEqual(@as(u32, 0x7F00), unit.read());
}

test "CRCREG is read-only and reads zero" {
    var unit = errors.Errors{};
    unit.store(0, 4, errors.mask.crc);
    try std.testing.expectEqual(@as(u32, 0), unit.read() & errors.mask.crc);
}

test "acknowledging the way a W1C part wants clears nothing" {
    var unit = errors.Errors{};
    unit.flags = 0x0008;
    unit.store(0, 4, 0x0008);
    try std.testing.expectEqual(@as(u32, 0x0008), unit.read());
}
