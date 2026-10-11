//! The remote protocol's requests against a live Zig core: halt reason,
//! qSupported, registers in target.xml order, and memory, read and written.
const std = @import("std");
const ra8 = @import("ra8");
const dispatch = ra8.gdb.rsp.dispatch;
const memmap = ra8.chip.core.memmap;
const Rig = @import("../../../session/view_ram.zig").Rig;

const base: u32 = memmap.sram_base;

// The Z, z and run-control tests ride along here because tests/all.zig is
// at its limit.
test {
    _ = @import("points_test.zig");
    _ = @import("server_test.zig");
    _ = @import("console_test.zig");
    _ = @import("zig_test.zig");
}

fn open(rig: *Rig) !void {
    rig.wire();
    const core = rig.view();
    try core.write(base, &[_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02 });
    try core.setRegister(.r0, 0x1122_3344);
    try core.setRegister(.r12, 0xc);
    try core.setRegister(.sp, base + 0x1f00);
    try core.setRegister(.pc, base + 0x18);
}

test "the halt reason, qSupported and qAttached" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("S05", try stub.answer("?", &out));
    try std.testing.expectEqualStrings("PacketSize=1000;qXfer:features:read+", try stub.answer("qSupported:multiprocess+;swbreak+", &out));
    try std.testing.expectEqualStrings("1", try stub.answer("qAttached", &out));
    try std.testing.expectEqualStrings("OK", try stub.answer("Hg0", &out));
}

test "an unknown request gets the empty reply" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", try stub.answer("vMustReplyEmpty", &out));
    try std.testing.expectEqualStrings("", try stub.answer("", &out));
}

// Words go out little-endian: r0 = 0x11223344 reads as 44332211.
test "g is seventeen little-endian words in target.xml order" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [256]u8 = undefined;
    const all = try stub.answer("g", &out);
    try std.testing.expectEqual(@as(usize, 17 * 8), all.len);
    try std.testing.expectEqualStrings("44332211", all[0..8]);
    try std.testing.expectEqualStrings("0c000000", all[12 * 8 .. 13 * 8]);
    try std.testing.expectEqualStrings("001f0022", all[13 * 8 .. 14 * 8]);
    try std.testing.expectEqualStrings("18000022", all[15 * 8 .. 16 * 8]);
}

test "p reads one register by its target.xml number" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("18000022", try stub.answer("pf", &out));
    try std.testing.expectEqualStrings("44332211", try stub.answer("p0", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("p11", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("pzz", &out));
}

test "m reads memory as hex, and an unmapped span is E01" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("deadbeef0102", try stub.answer("m22000000,6", &out));
    try std.testing.expectEqualStrings("E01", try stub.answer("m90000000,4", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("m22000000", &out));
}

test "an m reply that would not fit says so" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpace, stub.answer("m22000000,40", &out));
}

test "P writes one register, sent little-endian, and p reads it back" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("OK", try stub.answer("P3=78563412", &out));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try rig.view().register(.r3));
    try std.testing.expectEqualStrings("78563412", try stub.answer("p3", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("P11=00000000", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("P3=1234", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("P3", &out));
}

test "G writes all seventeen registers from what g sent" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var read: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    const all = try stub.answer("g", &read);
    sent[0] = 'G';
    @memcpy(sent[1 .. all.len + 1], all);
    @memcpy(sent[1 .. 1 + 8], "efbeadde");
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("OK", try stub.answer(sent[0 .. all.len + 1], &out));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), try rig.view().register(.r0));
    try std.testing.expectEqual(base + 0x18, try rig.view().register(.pc));
    try std.testing.expectEqualStrings("E00", try stub.answer("G0011", &out));
}

test "M writes hex and X writes binary, and m reads both back" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("OK", try stub.answer("M22000000,2:cafe", &out));
    try std.testing.expectEqualStrings("OK", try stub.answer("X22000002,4:\x23\x24\x7d\x2a", &out));
    try std.testing.expectEqualStrings("cafe23247d2a", try stub.answer("m22000000,6", &out));
    try std.testing.expectEqualStrings("OK", try stub.answer("X22000000,0:", &out));
}

test "a write that does not match its length, or lands nowhere, is refused" {
    var rig: Rig = .{};
    try open(&rig);
    const stub = dispatch.Dispatch{ .view = rig.view() };
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("E00", try stub.answer("M22000000,4:cafe", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("M22000000,2:caf", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("X22000000,2", &out));
    try std.testing.expectEqualStrings("E01", try stub.answer("M90000000,2:cafe", &out));
}

// Without a stop machine Z is not supported; with one it reaches the tables.
test "Z goes to the stop machine when one is attached" {
    var rig: Rig = .{};
    try open(&rig);
    var out: [16]u8 = undefined;
    const bare = dispatch.Dispatch{ .view = rig.view() };
    try std.testing.expectEqualStrings("", try bare.answer("Z0,22000008,2", &out));
    var machine = ra8.session.stop_machine.Machine{};
    const stub = dispatch.Dispatch{ .view = rig.view(), .machine = &machine };
    try std.testing.expectEqualStrings("OK", try stub.answer("Z0,22000008,2", &out));
    try std.testing.expect(machine.breaks.find(0x2200_0008) != null);
}
