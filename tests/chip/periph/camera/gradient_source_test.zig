//! Covers src/chip/periph/camera/gradient_source.zig: the CEU's default source
//! writes (x + y) & 0xFF, the bytes the CEU painted before it had sources.
const std = @import("std");
const ra8 = @import("ra8");

const ceu = ra8.chip.periph.ceu;
const gradient = ceu.camera.gradient;

test "the gradient is (column + row + index) & 0xFF and ignores the time" {
    const source = gradient.source();
    source.frame(0, .{ .width = 4, .lines = 2 });
    var line: [4]u8 = undefined;
    source.fill(3, 250, &line);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 253, 254, 255, 0 }, &line);
    source.frame(999_999, .{ .width = 4, .lines = 2 });
    var again: [4]u8 = undefined;
    source.fill(3, 250, &again);
    try std.testing.expectEqualSlices(u8, &line, &again);
    source.close();
}

test "a CEU starts on the gradient source and keeps the old pattern constants" {
    const fresh = ceu.Ceu.init();
    try std.testing.expectEqual(gradient.source().vtable, fresh.source.vtable);
    try std.testing.expectEqual(@as(u32, 256), ceu.pattern.chunk);
    try std.testing.expectEqual(@as(u32, 0xFF), ceu.pattern.mask);
}
