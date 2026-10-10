//! The hosts file `ctl --host` reads (RA8EMU-196).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const profiles = ra8.host.profiles;
const host_spawn = cli_app.host_spawn;

const text =
    \\# lab machines
    \\local here
    \\ssh lab bsikar@labvm emulator=/opt/ra8/ra8_emulator   # trailing comment
    \\ssh hil hil-box cache=/var/ra8 ssh=/usr/bin/ssh
    \\
;

test "a local profile has no fields" {
    try std.testing.expectEqual(profiles.Profile.local, try profiles.find(text, "here"));
}

test "an ssh profile keeps its destination and fills unnamed fields with defaults" {
    const lab = (try profiles.find(text, "lab")).ssh;
    try std.testing.expectEqualStrings("bsikar@labvm", lab.destination);
    try std.testing.expectEqualStrings("/opt/ra8/ra8_emulator", lab.emulator);
    try std.testing.expectEqualStrings(".cache/ra8_emulator/images", lab.cache);
    try std.testing.expectEqualStrings("ssh", lab.program);
    const hil = (try profiles.find(text, "hil")).ssh;
    try std.testing.expectEqualStrings("/var/ra8", hil.cache);
    try std.testing.expectEqualStrings("/usr/bin/ssh", hil.program);
}

test "an unknown name or a malformed line is refused" {
    try std.testing.expectError(error.UnknownHost, profiles.find(text, "nowhere"));
    try std.testing.expectError(error.BadHostsLine, profiles.find("ssh lab", "lab"));
    try std.testing.expectError(error.BadHostsLine, profiles.find("ssh lab box colour=red", "lab"));
    try std.testing.expectError(error.BadHostsLine, profiles.find("local here extra", "here"));
    try std.testing.expectError(error.BadHostsLine, profiles.find("telnet lab box", "lab"));
}

test "images are cached under their sha256 and paths are quoted for the remote shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "c/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.elf",
        try host_spawn.cachePath(a, "c", "abc"),
    );
    try std.testing.expectEqualStrings("'it'\\''s here'", try host_spawn.quote(a, "it's here"));
}
