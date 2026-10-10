//! CFDTMSTS[0]: the result byte software clears and the controller sets,
//! and the gate it puts on every later transmit request.
const std = @import("std");
const ra8 = @import("ra8");
const tx_status = ra8.chip.periph.canfd.tx_status;

test "a fresh mailbox is idle and takes a request" {
    var st = tx_status.Status{};
    try std.testing.expect(st.idle());
    try std.testing.expect(!st.done());
    try std.testing.expect(st.accepts());
    try std.testing.expect(st.quiet());
}

test "a completed transmit leaves TMTRF = 10b" {
    var st = tx_status.Status{};
    st.complete();
    try std.testing.expect(st.done());
    try std.testing.expect(!st.idle());
    try std.testing.expectEqual(tx_status.field.tmtrf_done, st.word);
}

test "a standing result turns the next request away" {
    var st = tx_status.Status{};
    st.complete();
    try std.testing.expect(!st.accepts());
    try std.testing.expectEqual(@as(u32, 1), st.stalled);
    try std.testing.expect(!st.accepts());
    try std.testing.expectEqual(@as(u32, 2), st.stalled);
}

test "clearing the byte frees the mailbox" {
    var st = tx_status.Status{};
    st.complete();
    st.store(0);
    try std.testing.expect(st.idle());
    try std.testing.expect(st.accepts());
    try std.testing.expectEqual(@as(u32, 0), st.stalled);
}

test "software cannot set TMTRF" {
    var st = tx_status.Status{};
    st.store(tx_status.field.tmtrf_done);
    try std.testing.expect(st.idle());
    st.store(tx_status.field.tmtrf);
    try std.testing.expect(st.idle());
}

test "a store that leaves TMTRF standing keeps it" {
    // Read-modify-write of the whole byte is what a driver preserving the
    // other bits would do, and it must not clear a result it wrote back.
    var st = tx_status.Status{};
    st.complete();
    st.store(st.word);
    try std.testing.expect(st.done());
}

test "the bits outside TMTRF are software's to write" {
    var st = tx_status.Status{};
    st.store(1);
    try std.testing.expectEqual(@as(u32, 1), st.word);
    try std.testing.expect(st.idle());
}

test "a half-cleared result is still a result" {
    // TMTRF = 11b, transmitted and aborted. Clearing only the low bit
    // leaves 10b standing, so the mailbox is not free.
    var st = tx_status.Status{};
    st.word = tx_status.field.tmtrf;
    st.store(tx_status.field.tmtrf_done);
    try std.testing.expectEqual(tx_status.field.tmtrf_done, st.word);
    try std.testing.expect(!st.idle());
}

test "the field sits where HUM Ch 41 puts it" {
    try std.testing.expectEqual(@as(u32, 0x074), tx_status.off_tmsts0);
    try std.testing.expectEqual(@as(u32, 0x06), tx_status.field.tmtrf);
    try std.testing.expectEqual(@as(u32, 0x04), tx_status.field.tmtrf_done);
}
