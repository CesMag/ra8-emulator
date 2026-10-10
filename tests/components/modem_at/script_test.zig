//! Covers src/components/modem_at/script.zig: the AT script and the V.250 match.
const std = @import("std");
const ra8 = @import("ra8");
const script = ra8.components.modem_at.script;

test "a scripted command gets its scripted answer" {
    try std.testing.expectEqualStrings("\r\nOK\r\n", script.answerFor("AT").?);
    try std.testing.expectEqualStrings("\r\n+CSQ: 17,99\r\n\r\nOK\r\n", script.answerFor("AT+CSQ").?);
}

test "a command outside the script has no answer" {
    try std.testing.expect(script.answerFor("AT+NOSUCH") == null);
    try std.testing.expect(script.answerFor("") == null);
}

test "the match is case-insensitive, as a command line is on the wire" {
    try std.testing.expectEqualStrings("\r\nOK\r\n", script.answerFor("at").?);
    try std.testing.expectEqualStrings("\r\n+CPIN: READY\r\n\r\nOK\r\n", script.answerFor("at+cpin?").?);
    try std.testing.expectEqualStrings("\r\n+CGATT: 1\r\n\r\nOK\r\n", script.answerFor("At+CgAtT?").?);
}

test "a prefix of a scripted command is not that command" {
    try std.testing.expect(script.answerFor("AT+CRE") == null);
    try std.testing.expect(script.answerFor("AT+CREG?X") == null);
}

test "registration enable carries the unsolicited report behind its OK" {
    const answer = script.answerFor("AT+CREG=1").?;
    try std.testing.expectEqualStrings("\r\nOK\r\n\r\n+CREG: 1\r\n", answer);
    try std.testing.expect(std.mem.indexOf(u8, answer, "+CREG: 1") != null);
}

test "every scripted response is framed the way a modem frames one" {
    for (&script.script) |entry| {
        try std.testing.expect(entry.command.len != 0);
        try std.testing.expect(std.mem.startsWith(u8, entry.response, "\r\n"));
        try std.testing.expect(std.mem.endsWith(u8, entry.response, "\r\n"));
    }
}

test "the error answer is the numeric CME form the script asked for" {
    try std.testing.expectEqualStrings("\r\n+CME ERROR: 4\r\n", script.cme_error);
    try std.testing.expect(script.answerFor("AT+CMEE=1") != null);
}
