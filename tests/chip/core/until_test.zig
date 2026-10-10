const std = @import("std");
const ra8 = @import("ra8");
const until = ra8.chip.core.stop.until;

test "a line without the text does not end the run" {
    var wait = until.Until{ .needle = "decode=96x96 PASS" };
    wait.line("reflow-webp-demo: boot");
    try std.testing.expect(!wait.met());
    try std.testing.expect(!wait.reached);
}

test "a line containing the text ends the run at the next boundary" {
    var wait = until.Until{ .needle = "decode=96x96 PASS" };
    wait.line("reflow-webp-demo: decode=96x96 PASS");
    try std.testing.expect(wait.met());
    try std.testing.expect(wait.reached);
}

test "the text matches literally, plus and dot included" {
    var wait = until.Until{ .needle = "cache+mpu PASS" };
    wait.line("cache_mpu_hil: cacheXmpu PASS");
    try std.testing.expect(!wait.met());
    wait.line("cache_mpu_hil: cache+mpu PASS");
    try std.testing.expect(wait.met());
}

test "a later line does not take the match back" {
    var wait = until.Until{ .needle = "PASS" };
    wait.line("x PASS");
    wait.line("idle");
    try std.testing.expect(wait.met());
}

test "empty text matches nothing" {
    var wait = until.Until{ .needle = "" };
    wait.line("anything");
    try std.testing.expect(!wait.met());
}
