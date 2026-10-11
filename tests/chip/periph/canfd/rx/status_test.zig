//! Covers src/chip/periph/canfd/rx_status.zig: CFDRFSTS's four flags, and the one
//! of them a store is allowed to lower.
const std = @import("std");
const ra8 = @import("ra8");
const rx_status = ra8.chip.periph.canfd.rx.status;

const field = rx_status.field;

test "an empty FIFO reports RFEMP and nothing else" {
    const status = rx_status.Status{};
    try std.testing.expectEqual(field.rfemp, status.read(true, false));
}

test "a FIFO holding a frame reports RFIF instead of RFEMP" {
    const status = rx_status.Status{};
    try std.testing.expectEqual(field.rfif, status.read(false, false));
}

test "a full FIFO reports RFFLL alongside RFIF" {
    const status = rx_status.Status{};
    try std.testing.expectEqual(field.rfif | field.rffll, status.read(false, true));
}

test "RFMLT stands once a frame has been lost, whatever the queue does next" {
    var status = rx_status.Status{};
    status.lose();
    try std.testing.expectEqual(field.rfif | field.rffll | field.rfmlt, status.read(false, true));
    // Drained back to empty: the latch is about the frame that went, not
    // about how much room there is now.
    try std.testing.expectEqual(field.rfemp | field.rfmlt, status.read(true, false));
}

test "a store of zero lowers RFMLT and counts the acknowledgement" {
    var status = rx_status.Status{};
    status.lose();
    status.store(0, 4, 0);
    try std.testing.expect(!status.lost_latched);
    try std.testing.expectEqual(@as(u32, 1), status.acknowledged);
    try std.testing.expectEqual(@as(u32, 0), status.invented);
}

test "a store of ones cannot raise RFMLT and is counted as invented" {
    var status = rx_status.Status{};
    status.store(0, 4, field.rfmlt);
    try std.testing.expect(!status.lost_latched);
    try std.testing.expectEqual(@as(u32, 1), status.invented);
    try std.testing.expectEqual(@as(u32, 0), status.acknowledged);
}

test "a W1C-style acknowledgement leaves the latch standing" {
    var status = rx_status.Status{};
    status.lose();
    // A driver acking the way most CAN parts want writes a one at the flag.
    // Here that raises nothing and clears nothing, so the run says a driver
    // tried and the overrun is still on the register.
    status.store(0, 4, field.rfmlt);
    try std.testing.expect(status.lost_latched);
    try std.testing.expectEqual(@as(u32, 1), status.invented);
}

test "a store cannot raise RFEMP, RFFLL or RFIF either" {
    var status = rx_status.Status{};
    status.store(0, 4, field.rfemp | field.rffll | field.rfif);
    try std.testing.expectEqual(@as(u32, 1), status.invented);
    try std.testing.expectEqual(field.rfemp, status.read(true, false));
}

test "a store above the flags names none of them and lowers nothing" {
    var status = rx_status.Status{};
    status.lose();
    status.store(1, 1, 0);
    try std.testing.expect(status.lost_latched);
    try std.testing.expectEqual(@as(u32, 0), status.acknowledged);
    try std.testing.expectEqual(@as(u32, 0), status.invented);
}

test "a byte store at the flags still carries the clear" {
    var status = rx_status.Status{};
    status.lose();
    status.store(0, 1, 0);
    try std.testing.expect(!status.lost_latched);
}

test "clearing a latch that was never set counts no acknowledgement" {
    var status = rx_status.Status{};
    status.store(0, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), status.acknowledged);
    try std.testing.expect(status.quiet());
}

test "a status nothing touched is quiet" {
    const status = rx_status.Status{};
    try std.testing.expect(status.quiet());
}
