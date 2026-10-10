//! The harness's run file on the serving host (RA8EMU-768, RA8EMU-1020).
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");

const image_path = "tests/fixtures/display/ra8_ui.elf";
const input_path = "tests/fixtures/display/tap.input";

test "restoring from a missing file fails and the session keeps running" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path, .input_script = input_path });
    defer opened.deinit();
    try opened.session().waitSettled(2_000_000_000);
    try std.testing.expectError(error.FileNotFound, opened.stateFiles().restore("tests/fixtures/display/missing.ra8snap"));
    try opened.session().waitSettled(2_000_000_000);
}
