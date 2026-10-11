//! Covers the `--count-pc` wiring (RA8EMU-951): a Zig run's retire hook
//! counts the asked addresses, with the interworking bit cleared, and
//! nothing asks for a listener when no address was named.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const zig_break = cli_app.zig_run.break_sym;

test "only hits gives a listener and every retire is counted" {
    var hits: ra8.session.pc_hits.Hits = .{};
    var retire: zig_break.Retire = .{ .hits = &hits };
    try std.testing.expect(retire.listener() != null);
    hits.want(0x0200_1000);
    hits.want(0x0200_2000);
    for ([_]u32{ 0x0200_1000, 0x0200_1000, 0x0200_2000, 0x0200_3000 }) |at| retire.instruction(at);
    const asked = hits.asked();
    try std.testing.expectEqual(@as(u64, 2), asked[0].hits);
    try std.testing.expectEqual(@as(u64, 1), asked[1].hits);
}

test "the interworking bit is cleared before a hit lands" {
    var hits: ra8.session.pc_hits.Hits = .{};
    var retire: zig_break.Retire = .{ .hits = &hits };
    hits.want(0x0200_1000);
    retire.instruction(0x0200_1001);
    try std.testing.expectEqual(@as(u64, 1), hits.asked()[0].hits);
}

test "no hits and no break gives no listener" {
    var retire: zig_break.Retire = .{};
    try std.testing.expect(retire.listener() == null);
}
