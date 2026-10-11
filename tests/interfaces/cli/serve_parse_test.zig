//! Tests for serve_main.parse (RA8EMU-833, RA8EMU-1147): the options sit
//! before the transport, in any order, each at most once.
const std = @import("std");
const cli_app = @import("cli_app");
const parse = cli_app.serve_main.parse;

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
