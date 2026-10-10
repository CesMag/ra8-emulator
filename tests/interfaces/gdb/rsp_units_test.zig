//! Tests for src/interfaces/gdb/rsp_units.zig: a debugger store into the DWT and
//! DEMCR reaches the models the way a firmware store does.
const std = @import("std");
const ra8 = @import("ra8");
const dispatch = ra8.gdb.rsp_dispatch;
const Rig = @import("../../session/view_ram.zig").Rig;

const demcr: u32 = 0xE000_EDFC;
const dwt_ctrl: u32 = 0xE000_1000;
const comp0: u32 = 0xE000_1020;
const function0: u32 = 0xE000_1028;

fn store(stub: dispatch.Dispatch, address: u32, value: u32) !void {
    var request: [32]u8 = undefined;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    const text = try std.fmt.bufPrint(&request, "M{x},4:{s}", .{ address, std.fmt.bytesToHex(bytes, .lower) });
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("OK", try stub.answer(text, &out));
}

test "a debugger store to DEMCR sets and clears TRCENA in the model" {
    var rig: Rig = .{};
    rig.wire();
    var machine = ra8.session.stop_machine.Machine{};
    const stub = dispatch.Dispatch{ .machine = &machine, .view = rig.view() };
    try store(stub, demcr, 1 << 24);
    try std.testing.expect(machine.dwt.trcena);
    try store(stub, demcr, 0);
    try std.testing.expect(!machine.dwt.trcena);
}

test "a debugger store to a comparator reaches the model" {
    var rig: Rig = .{};
    rig.wire();
    var machine = ra8.session.stop_machine.Machine{};
    const stub = dispatch.Dispatch{ .machine = &machine, .view = rig.view() };
    try store(stub, demcr, 1 << 24);
    try store(stub, comp0, 40);
    try store(stub, function0, 0x11);
    try std.testing.expectEqual(@as(u32, 40), machine.dwt.comps[0]);
    try std.testing.expect(machine.dwt.watchesCycles());
}

test "a debugger store over DWT_CTRL keeps NUMCOMP" {
    var rig: Rig = .{};
    rig.wire();
    var machine = ra8.session.stop_machine.Machine{};
    machine.dwt.numcomp = 4;
    const stub = dispatch.Dispatch{ .machine = &machine, .view = rig.view() };
    try store(stub, dwt_ctrl, 1);
    var bytes: [4]u8 = undefined;
    try rig.view().read(dwt_ctrl, &bytes);
    try std.testing.expectEqual(@as(u32, 0x4000_0001), std.mem.readInt(u32, &bytes, .little));
}

test "a store outside the units leaves the model alone" {
    var rig: Rig = .{};
    rig.wire();
    var machine = ra8.session.stop_machine.Machine{};
    const stub = dispatch.Dispatch{ .machine = &machine, .view = rig.view() };
    try store(stub, ra8.chip.core.memmap.sram_base, 0xffff_ffff);
    try std.testing.expect(!machine.dwt.trcena);
    try std.testing.expectEqual(@as(u32, 0), machine.dwt.comps[0]);
}
