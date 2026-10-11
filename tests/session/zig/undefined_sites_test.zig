//! Covers src/session/zig/undefined_sites.zig: `--stop-on-undefined` on a
//! Zig run (RA8EMU-603).
const std = @import("std");
const cli_app = @import("cli_app");

const zig_undefined = cli_app.zig.run.undefined_sites;

fn oneSite() zig_undefined.Found {
    var found: zig_undefined.Found = .{};
    found.count = 1;
    found.sites[0] = .{ .address = 0x0200_0100, .encoding = 0xEB00_0F0F };
    return found;
}

test "an arrival is counted whether or not it stops the run" {
    var found = oneSite();
    try std.testing.expect(!zig_undefined.arrive(&found, 0x0200_0101));
    try std.testing.expectEqual(@as(u32, 1), found.sites[0].runs);
    try std.testing.expect(!zig_undefined.arrive(&found, 0x0200_0104));
    try std.testing.expectEqual(@as(u64, 1), found.arrivals());
}

test "with the flag, the first arrival holds the run" {
    var found = oneSite();
    found.stopOnRun();
    try std.testing.expect(zig_undefined.arrive(&found, 0x0200_0100));
    try std.testing.expectEqual(@as(u32, 0x0200_0100), found.stoppedAt().?.address);
}

test "no flag, no sweep; no sites, no guard" {
    var empty: zig_undefined.Found = .{};
    try std.testing.expect(zig_undefined.guard(&empty) == null);
    var found = oneSite();
    try std.testing.expect(zig_undefined.guard(&found) != null);
}
