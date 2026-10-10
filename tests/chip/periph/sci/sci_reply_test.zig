//! Covers src/chip/periph/sci/sci_reply.zig: the console line typed back once
//! the firmware prints its prompt (RA8EMU-626).
const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.chip.periph.sci;
const sci_reply = ra8.chip.periph.sci_reply;

fn console() sci.Sci {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
    return unit;
}

fn drained(unit: *sci.Sci, into: []u8) []const u8 {
    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    var count: usize = 0;
    while (count < into.len) : (count += 1) {
        const byte: u8 = @truncate(unit.read(rdr, 4));
        if (byte == 0) break;
        into[count] = byte;
    }
    return into[0..count];
}

test "a reply splits on the first equals sign and refuses an empty prompt" {
    const reply = try sci_reply.Reply.parse("READY v1=RA8NET1:61:62:");
    try std.testing.expectEqualStrings("READY v1", reply.prompt);
    try std.testing.expectEqualStrings("RA8NET1:61:62:", reply.text);
    try std.testing.expectError(error.BadReply, sci_reply.Reply.parse("=line"));
    try std.testing.expectError(error.BadReply, sci_reply.Reply.parse("no separator"));
}

test "nothing is typed before the prompt line" {
    var unit = console();
    var reply = try sci_reply.Reply.parse("READY v1=hello");
    reply.line("booting");
    reply.poll(&unit);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", drained(&unit, &bytes));
}

test "the prompt line queues the reply and a newline once" {
    var unit = console();
    var reply = try sci_reply.Reply.parse("READY v1=hello");
    reply.line("ra8_net_provision: READY v1");
    reply.poll(&unit);
    reply.line("READY v1");
    reply.poll(&unit);
    var bytes: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello\n", drained(&unit, &bytes));
    try std.testing.expect(reply.sent);
}

test "an unarmed reply ignores every line" {
    var unit = console();
    var reply: sci_reply.Reply = .{};
    reply.line("READY v1");
    reply.poll(&unit);
    try std.testing.expect(!reply.armed());
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", drained(&unit, &bytes));
}
