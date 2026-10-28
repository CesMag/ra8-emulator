//! Tests for serve/main.zig parse (RA8EMU-833, RA8EMU-1147): the options sit
//! before the transport, in any order, each at most once.
const std = @import("std");
const cli_app = @import("cli_app");
const parse = cli_app.serve.main.parse;

test "a bare transport asks for no options" {
    const asked = parse(&.{ "ra8_emulator", "serve", "--stdio", "a.elf" }).?;
    try std.testing.expectEqualStrings("a.elf", asked.elf);
    try std.testing.expect(!asked.folded);
    try std.testing.expect(asked.cpu1 == null);
}

test "--cpu1 and --profile-folded come in either order" {
    const one = parse(&.{ "ra8_emulator", "serve", "--cpu1", "b.elf", "--profile-folded", "--stdio", "a.elf" }).?;
    const two = parse(&.{ "ra8_emulator", "serve", "--profile-folded", "--cpu1", "b.elf", "--stdio", "a.elf" }).?;
    for ([_]@TypeOf(one){ one, two }) |asked| {
        try std.testing.expect(asked.folded);
        try std.testing.expectEqualStrings("b.elf", asked.cpu1.?);
        try std.testing.expectEqualStrings("a.elf", asked.elf);
    }
}

test "--cpu1 works with --listen too" {
    const asked = parse(&.{ "ra8_emulator", "serve", "--cpu1", "b.elf", "--listen", "unix:/tmp/s", "a.elf" }).?;
    try std.testing.expectEqualStrings("b.elf", asked.cpu1.?);
    try std.testing.expect(asked.where == .listen);
}

test "a repeated option, a --cpu1 with no image or stray words are refused" {
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--cpu1", "b.elf", "--cpu1", "c.elf", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--profile-folded", "--profile-folded", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--cpu1" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--stdio", "a.elf", "extra" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve" }) == null);
}

test "--sd-dir and repeated --app fill the card the server opens with (RA8EMU-1139)" {
    const asked = parse(&.{ "ra8_emulator", "serve", "--app", "h.ra8app", "--sd-dir", "card", "--app", "f.ra8app", "--stdio", "a.elf" }).?;
    try std.testing.expectEqualStrings("card", asked.sdhi.dir.?);
    try std.testing.expectEqual(@as(usize, 2), asked.sdhi.appPaths().len);
    try std.testing.expectEqualStrings("f.ra8app", asked.sdhi.appPaths()[1]);
    try std.testing.expectEqualStrings("a.elf", asked.elf);
}

test "--sd-dir is taken at most once" {
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--sd-dir", "a", "--sd-dir", "b", "--stdio", "a.elf" }) == null);
}

test "--allow-state-files parses once (RA8EMU-1175)" {
    const asked = parse(&.{ "ra8_emulator", "serve", "--allow-state-files", "--listen", "tcp:0.0.0.0:7000", "a.elf" }).?;
    try std.testing.expect(asked.allow_state_files);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--allow-state-files", "--allow-state-files", "--stdio", "a.elf" }) == null);
}

test "--history-budget caps the served history's share next to --history (RA8EMU-1196)" {
    const asked = parse(&.{ "ra8_emulator", "serve", "--history", "h", "--history-budget", "268435456", "--stdio", "a.elf" }).?;
    try std.testing.expectEqual(@as(?u64, 268435456), asked.history_budget);
    try std.testing.expectEqualStrings("h", asked.history.?);
}

test "--history-budget without --history, twice, or non-numeric is refused" {
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history-budget", "100", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "h", "--history-budget", "1", "--history-budget", "2", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "h", "--history-budget", "abc", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "off", "--history-budget", "100", "--stdio", "a.elf" }) == null);
}

test "--ram-budget caps the RAM-only history next to --history off (RA8EMU-1196)" {
    const asked = parse(&.{ "ra8_emulator", "serve", "--history", "off", "--ram-budget", "268435456", "--stdio", "a.elf" }).?;
    try std.testing.expectEqual(@as(?u64, 268435456), asked.ram_budget);
    try std.testing.expect(asked.history_off);
    try std.testing.expect(asked.history == null);
}

test "--ram-budget without --history off, twice, or non-numeric is refused" {
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--ram-budget", "100", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "h", "--ram-budget", "100", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "off", "--ram-budget", "1", "--ram-budget", "2", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "off", "--ram-budget", "abc", "--stdio", "a.elf" }) == null);
}

test "a second --history after off is refused (RA8EMU-1196)" {
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "off", "--history", "h", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "h", "--history", "off", "--stdio", "a.elf" }) == null);
}

test "isLoopback separates loopback from the world (RA8EMU-1175)" {
    const listen = cli_app.serve.listen;
    try std.testing.expect(listen.isLoopback(try std.Io.net.IpAddress.parse("127.0.0.1", 0)));
    try std.testing.expect(listen.isLoopback(try std.Io.net.IpAddress.parse("127.9.9.9", 0)));
    try std.testing.expect(listen.isLoopback(try std.Io.net.IpAddress.parse("::1", 0)));
    try std.testing.expect(!listen.isLoopback(try std.Io.net.IpAddress.parse("0.0.0.0", 0)));
    try std.testing.expect(!listen.isLoopback(try std.Io.net.IpAddress.parse("192.168.1.4", 0)));
}

test "--reopen names a kept session in the --history root and nothing else" {
    const id = "0123456789abcdef0123456789abcdef";
    const asked = parse(&.{ "ra8_emulator", "serve", "--history", "h", "--reopen", id, "--stdio", "a.elf" }).?;
    try std.testing.expectEqualStrings(id, asked.reopen.?);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--reopen", id, "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--history", "h", "--kept", "--reopen", id, "--stdio", "a.elf" }) == null);
}

test "--usbip takes a port, once" {
    const asked = parse(&.{ "ra8_emulator", "serve", "--usbip", "3240", "--stdio", "a.elf" }).?;
    try std.testing.expectEqual(@as(?u16, 3240), asked.usbip);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--stdio", "a.elf" }).?.usbip == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--usbip", "1", "--usbip", "2", "--stdio", "a.elf" }) == null);
    try std.testing.expect(parse(&.{ "ra8_emulator", "serve", "--usbip", "x", "--stdio", "a.elf" }) == null);
}
