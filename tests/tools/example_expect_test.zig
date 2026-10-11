//! Covers tools/example/expect.zig: README verdicts for conf-less examples.
const std = @import("std");
const table = @import("example_table");

const expect = table.expect;

test "an image with no entry has no README verdict" {
    try std.testing.expect(expect.find("blink_hal.elf") == null);
}

test "a match is on the whole file name" {
    try std.testing.expect(expect.find("lin_commander_hil") == null);
    try std.testing.expect(expect.find("xlin_commander_hil.elf") == null);
}

test "lin_commander_hil passes on a sent frame" {
    const found = expect.find("lin_commander_hil.elf").?;
    try std.testing.expectEqual(.pass, expect.judge(found, "lin_commander_hil: frame sent").?);
}

test "lin_commander_hil fails on a refused frame" {
    const found = expect.find("lin_commander_hil.elf").?;
    try std.testing.expectEqual(.fail, expect.judge(found, "lin_commander_hil: LIN TX error").?);
}

test "no console or an unrelated line leaves the row undecided" {
    const found = expect.find("lin_commander_hil.elf").?;
    try std.testing.expect(expect.judge(found, null) == null);
    try std.testing.expect(expect.judge(found, "lin_commander_hil: boot") == null);
}

test "a README verdict decides a row the console alone leaves unknown" {
    const found = expect.find("lin_commander_hil.elf").?;
    var row = table.Row{ .console = "lin_commander_hil: frame sent" };
    try std.testing.expectEqual(table.Verdict.unknown, row.verdict());
    row.hil = expect.judge(found, row.console);
    try std.testing.expectEqual(table.Verdict.pass, row.verdict());
}

test "usb_host_file_ops passes on the ninth step and fails on a refused one" {
    const found = expect.find("usb_host_file_ops.elf").?;
    try std.testing.expectEqual(.pass, expect.judge(found, "ra8d2 fileops: ALL FILE OPS PASSED").?);
    try std.testing.expectEqual(.fail, expect.judge(found, "ra8d2 fileops: FAIL write").?);
    try std.testing.expect(expect.judge(found, "ra8d2 fileops: [9/9] unlink USBDONE.TXT") == null);
}
