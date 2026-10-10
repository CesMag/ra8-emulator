const std = @import("std");
const ra8 = @import("ra8");
const sd_trace = ra8.components.sd_card.trace;

test "an ordinary command is written with its index and argument" {
    var buf: sd_trace.Buffer = undefined;
    try std.testing.expectEqualStrings("sd CMD17 arg 0x00000810", sd_trace.line(&buf, 17, 0x810, false));
}

test "a command behind CMD55 is written as an ACMD" {
    var buf: sd_trace.Buffer = undefined;
    try std.testing.expectEqualStrings("sd ACMD41 arg 0x40000000", sd_trace.line(&buf, 41, 0x4000_0000, true));
}

test "CMD41 and ACMD41 do not read the same" {
    var plain: sd_trace.Buffer = undefined;
    var app: sd_trace.Buffer = undefined;
    const a = sd_trace.line(&plain, 41, 0, false);
    const b = sd_trace.line(&app, 41, 0, true);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "the argument keeps its leading zeros so a column of lines aligns" {
    var buf: sd_trace.Buffer = undefined;
    try std.testing.expectEqualStrings("sd CMD0 arg 0x00000000", sd_trace.line(&buf, 0, 0, false));
}

test "the widest command still fits the buffer" {
    var buf: sd_trace.Buffer = undefined;
    const out = sd_trace.line(&buf, 255, 0xFFFF_FFFF, true);
    try std.testing.expect(out.len > 0);
    try std.testing.expect(out.len <= sd_trace.width);
}
