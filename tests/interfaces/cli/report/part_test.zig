//! Covers src/interfaces/cli/report/part.zig: the part line a non-default
//! run prints, and that the default part prints none.
const std = @import("std");
const cli_app = @import("cli_app");

const report_part = cli_app.report_part;

test "an RA8P1 run names its part and its cited geometry" {
    var buf: [256]u8 = undefined;
    const text = try report_part.line(&buf, .ra8p1);
    try std.testing.expect(std.mem.startsWith(u8, text, "PART: RA8P1 MRAM 1024 KB @0x02000000, SRAM 1664 KB @0x22000000"));
    try std.testing.expect(std.mem.indexOf(u8, text, "CPU0 TCM 256 KB + cache 32 KB, CPU1 TCM 128 KB + cache 32 KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Table 1.15") != null);
}

test "the default RA8D2 run prints no part line" {
    try std.testing.expect(!report_part.shown(.ra8d2));
    try std.testing.expect(report_part.shown(.ra8p1));
}
