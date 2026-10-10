//! Covers src/chip/core/fp_context.zig.
const std = @import("std");
const ra8 = @import("ra8");
const fp = ra8.chip.core.csel.fp_context;

const fpca = fp.control_fpca;
const sfpa = fp.control_sfpa;

test "decode reads the entry stub's save and restore" {
    const save = fp.decode(0xED6D, 0xCF81).?;
    try std.testing.expectEqual(fp.Register.fpcxt_ns, save.register);
    try std.testing.expect(!save.load and save.pre and !save.add and save.writeback);
    try std.testing.expectEqual(@as(u4, 13), save.base);
    try std.testing.expectEqual(@as(u32, 0x1FFC), save.address(0x2000));
    const restore = fp.decode(0xECFD, 0xCF81).?;
    try std.testing.expect(restore.load and !restore.pre and restore.add and restore.writeback);
    try std.testing.expectEqual(@as(u32, 0x2000), restore.address(0x2000));
    try std.testing.expectEqual(@as(u32, 0x2004), restore.moved(0x2000));
}

test "decode names FPSCR and FPCXT_S and refuses the rest" {
    try std.testing.expectEqual(fp.Register.fpscr, fp.decode(0xED2D, 0x2F81).?.register);
    try std.testing.expectEqual(fp.Register.fpcxt_s, fp.decode(0xED6D, 0xEF81).?.register);
    // VPR, P = 0 with W = 0, Rn = PC, and a plain VSTR of S0.
    try std.testing.expectEqual(@as(?fp.Transfer, null), fp.decode(0xED6D, 0x8F81));
    try std.testing.expectEqual(@as(?fp.Transfer, null), fp.decode(0xEC4D, 0xCF81));
    try std.testing.expectEqual(@as(?fp.Transfer, null), fp.decode(0xED6F, 0xCF81));
    try std.testing.expectEqual(@as(?fp.Transfer, null), fp.decode(0xED8D, 0x0A00));
}

test "FPCXT_NS store with a Secure context keeps FPSCR and carries SFPA" {
    var state = fp.State{ .fpscr = 0xF300_0001, .control = fpca | sfpa };
    try std.testing.expectEqual(@as(u32, 0x8300_0001), fp.store(.fpcxt_ns, &state));
    try std.testing.expectEqual(@as(u32, 0xF300_0001), state.fpscr);
}

test "FPCXT_NS store with a Non-Secure context resets FPSCR" {
    var state = fp.State{ .fpscr = 0x0300_0001, .control = fpca };
    try std.testing.expectEqual(@as(u32, 0x0300_0001), fp.store(.fpcxt_ns, &state));
    try std.testing.expectEqual(fp.default_fpscr, state.fpscr);
}

test "FPCXT_NS with no active context stores the default and ignores a load" {
    var state = fp.State{ .fpscr = 0x0300_0001, .control = sfpa };
    try std.testing.expectEqual(@as(u32, 0), fp.store(.fpcxt_ns, &state));
    fp.load(.fpcxt_ns, &state, 0x0000_0005);
    try std.testing.expectEqual(@as(u32, 0x0300_0001), state.fpscr);
    try std.testing.expectEqual(sfpa, state.control);
}

test "FPCXT_S store clears SFPA and a load puts bit 31 back" {
    var state = fp.State{ .fpscr = 0x0040_0000, .control = fpca | sfpa };
    const saved = fp.store(.fpcxt_s, &state);
    try std.testing.expectEqual(@as(u32, 0x8040_0000), saved);
    try std.testing.expectEqual(fpca, state.control);
    fp.load(.fpcxt_s, &state, saved);
    try std.testing.expectEqual(fpca | sfpa, state.control);
    try std.testing.expectEqual(@as(u32, 0x0040_0000), state.fpscr);
}

test "FPSCR moves whole" {
    var state = fp.State{ .fpscr = 0xF000_0010, .control = 0 };
    try std.testing.expectEqual(@as(u32, 0xF000_0010), fp.store(.fpscr, &state));
    fp.load(.fpscr, &state, 0x8000_0000);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), state.fpscr);
}
