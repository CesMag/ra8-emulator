//! The IWDTRR sequence: two bytes, in order, or nothing.
const std = @import("std");
const ra8 = @import("ra8");

const refresh = ra8.chip.periph.iwdt_refresh;

test "the two bytes in order reload the counter" {
    var seq = refresh.Sequence{};
    try std.testing.expectEqual(refresh.Step.primed, seq.accept(refresh.byte.first));
    try std.testing.expectEqual(refresh.Step.reloaded, seq.accept(refresh.byte.second));
}

test "a lone 0xFF refreshes nothing, whatever IWDTRR reset to" {
    var seq = refresh.Sequence{};
    try std.testing.expectEqual(refresh.Step.ignored, seq.accept(refresh.byte.second));
}

test "the sequence does not stay armed after it completes" {
    var seq = refresh.Sequence{};
    _ = seq.accept(refresh.byte.first);
    _ = seq.accept(refresh.byte.second);
    try std.testing.expectEqual(refresh.Step.ignored, seq.accept(refresh.byte.second));
}

test "the bytes have to arrive in order" {
    var seq = refresh.Sequence{};
    try std.testing.expectEqual(refresh.Step.ignored, seq.accept(0x5A));
    try std.testing.expectEqual(refresh.Step.primed, seq.accept(refresh.byte.first));
    try std.testing.expectEqual(refresh.Step.reloaded, seq.accept(refresh.byte.second));
}

test "any other byte between the two drops the sequence" {
    var seq = refresh.Sequence{};
    _ = seq.accept(refresh.byte.first);
    try std.testing.expectEqual(refresh.Step.ignored, seq.accept(0x01));
    try std.testing.expectEqual(refresh.Step.ignored, seq.accept(refresh.byte.second));
}

test "a repeated first byte stays primed" {
    var seq = refresh.Sequence{};
    _ = seq.accept(refresh.byte.first);
    try std.testing.expectEqual(refresh.Step.primed, seq.accept(refresh.byte.first));
    try std.testing.expect(seq.pending());
    try std.testing.expectEqual(refresh.Step.reloaded, seq.accept(refresh.byte.second));
}

test "pending is only true between the two bytes" {
    var seq = refresh.Sequence{};
    try std.testing.expect(!seq.pending());
    _ = seq.accept(refresh.byte.first);
    try std.testing.expect(seq.pending());
    _ = seq.accept(refresh.byte.second);
    try std.testing.expect(!seq.pending());
}

test "every step names itself" {
    try std.testing.expectEqualStrings("dropped", refresh.Step.ignored.name());
    try std.testing.expectEqualStrings("primed", refresh.Step.primed.name());
    try std.testing.expectEqualStrings("reloaded", refresh.Step.reloaded.name());
}
