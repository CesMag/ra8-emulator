const std = @import("std");
const ra8 = @import("ra8");
const compare = ra8.chip.periph.ulpt.compare;

test "an untouched pair is quiet" {
    const pair = compare.Pair{};
    try std.testing.expect(pair.quiet());
}

test "storing a compare value is a touch" {
    var pair = compare.Pair{};
    pair.set(.a, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x1234), pair.a);
    try std.testing.expectEqual(@as(u32, 1), pair.touches);
    try std.testing.expect(!pair.quiet());
}

test "a read-side touch is counted without changing a value" {
    var pair = compare.Pair{};
    pair.set(.b, 0x40);
    pair.touch();
    try std.testing.expectEqual(@as(u32, 2), pair.touches);
    try std.testing.expectEqual(@as(u32, 0x40), pair.b);
}

test "a compare of zero is unarmed" {
    var pair = compare.Pair{};
    try std.testing.expect(!pair.armed(.a));
    try std.testing.expect(!pair.armed(.b));
    // A count sweeping the whole range must not match it.
    try std.testing.expectEqual(@as(u8, 0), pair.step(0x100, 0x00, false, 0x100));
}

test "a plain down-count past A raises TCMAF once" {
    var pair = compare.Pair{};
    pair.set(.a, 0x80);
    const raised = pair.step(0x100, 0x40, false, 0x100);
    try std.testing.expectEqual(compare.flag.cmaf, raised);
    try std.testing.expectEqual(@as(u32, 1), pair.matches_a);
    try std.testing.expectEqual(@as(u32, 0), pair.matches_b);
}

test "a count that stops short of A raises nothing" {
    var pair = compare.Pair{};
    pair.set(.a, 0x40);
    try std.testing.expectEqual(@as(u8, 0), pair.step(0x100, 0x80, false, 0x100));
    try std.testing.expectEqual(@as(u32, 0), pair.matches_a);
}

test "landing exactly on A counts as passing it" {
    var pair = compare.Pair{};
    pair.set(.a, 0x80);
    try std.testing.expectEqual(compare.flag.cmaf, pair.step(0x100, 0x80, false, 0x100));
}

test "starting exactly on A does not re-match it" {
    var pair = compare.Pair{};
    pair.set(.a, 0x80);
    try std.testing.expectEqual(@as(u8, 0), pair.step(0x80, 0x40, false, 0x100));
}

test "both compares in one chunk raise both flags" {
    var pair = compare.Pair{};
    pair.set(.a, 0xC0);
    pair.set(.b, 0x60);
    const raised = pair.step(0x100, 0x20, false, 0x100);
    try std.testing.expectEqual(compare.flag.cmaf | compare.flag.cmbf, raised);
    try std.testing.expectEqual(@as(u32, 1), pair.matches_a);
    try std.testing.expectEqual(@as(u32, 1), pair.matches_b);
}

test "a wrapping chunk matches a compare below where it started" {
    var pair = compare.Pair{};
    pair.set(.a, 0x10);
    // 0x20 down through zero, reloading to 0x100 and landing on 0xF0.
    try std.testing.expectEqual(compare.flag.cmaf, pair.step(0x20, 0xF0, true, 0x100));
}

test "a wrapping chunk matches a compare it reached after the reload" {
    var pair = compare.Pair{};
    pair.set(.b, 0xF8);
    try std.testing.expectEqual(compare.flag.cmbf, pair.step(0x20, 0xF0, true, 0x100));
}

test "a wrapping chunk skips a compare in neither half" {
    var pair = compare.Pair{};
    pair.set(.a, 0x80);
    try std.testing.expectEqual(@as(u8, 0), pair.step(0x20, 0xF0, true, 0x100));
    try std.testing.expectEqual(@as(u32, 0), pair.matches_a);
}

test "repeated crossings accumulate per compare" {
    var pair = compare.Pair{};
    pair.set(.a, 0x80);
    // Down past it once, then round the reload and down past it again.
    _ = pair.step(0x100, 0x40, false, 0x100);
    _ = pair.step(0x40, 0xF0, true, 0x100);
    _ = pair.step(0xF0, 0x20, false, 0x100);
    try std.testing.expectEqual(@as(u32, 2), pair.matches_a);
}

test "a wrap that reloads above the compare does not match it" {
    var pair = compare.Pair{};
    pair.set(.a, 0x80);
    // 0x40 down through zero, landing on 0xC0: the chunk covered [0, 0x40)
    // and [0xC0, 0x100], and 0x80 is in neither.
    try std.testing.expectEqual(@as(u8, 0), pair.step(0x40, 0xC0, true, 0x100));
    try std.testing.expectEqual(@as(u32, 0), pair.matches_a);
}

test "value and matches answer per side" {
    var pair = compare.Pair{};
    pair.set(.a, 0x11);
    pair.set(.b, 0x22);
    _ = pair.step(0x100, 0x00, false, 0x100);
    try std.testing.expectEqual(@as(u32, 0x11), pair.value(.a));
    try std.testing.expectEqual(@as(u32, 0x22), pair.value(.b));
    try std.testing.expectEqual(@as(u32, 1), pair.matches(.a));
    try std.testing.expectEqual(@as(u32, 1), pair.matches(.b));
}

test "the flag masks sit above TUNDF in AGTCR order" {
    try std.testing.expectEqual(@as(u8, 0x20), compare.flag.undf);
    try std.testing.expectEqual(@as(u8, 0x40), compare.flag.cmaf);
    try std.testing.expectEqual(@as(u8, 0x80), compare.flag.cmbf);
    try std.testing.expectEqual(@as(u8, 0xE0), compare.flag.all);
}

test "crossed is the whole rule, both halves of a wrap" {
    try std.testing.expect(compare.crossed(0x100, 0x40, false, 0x100, 0x80));
    try std.testing.expect(!compare.crossed(0x100, 0x40, false, 0x100, 0x20));
    try std.testing.expect(compare.crossed(0x20, 0xF0, true, 0x100, 0x10));
    try std.testing.expect(compare.crossed(0x20, 0xF0, true, 0x100, 0xFF));
    try std.testing.expect(!compare.crossed(0x20, 0xF0, true, 0x100, 0x80));
}
