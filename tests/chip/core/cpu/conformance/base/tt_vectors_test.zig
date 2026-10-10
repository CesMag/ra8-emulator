//! Covers src/chip/core/cpu/conformance/base/tt_vectors.zig: each vector runs
//! through the `tt` group with no MPU, and with an attribution source that
//! echoes the vector's response word when the vector asks for one.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.tt_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const Attribution = cpu_ns.cpu.attribution.Attribution;
const State = cpu_ns.cpu.attribution.State;
const fixture = @import("../../exception/ram.zig");

/// Answers `resp` for every target and records the state it was asked from.
const Echo = struct {
    resp: u32,
    asked: vectors.Asked = .not_asked,

    fn state(context: *anyopaque, address: u32) State {
        _ = context;
        _ = address;
        return .secure;
    }

    fn respond(context: *anyopaque, address: u32, secure: bool) u32 {
        _ = address;
        const self: *Echo = @ptrCast(@alignCast(context));
        self.asked = if (secure) .secure else .non_secure;
        return self.resp;
    }

    fn source(self: *Echo) Attribution {
        return .{ .context = self, .stateFn = state, .respondFn = respond };
    }
};

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    var echo: Echo = .{ .resp = in.resp };
    if (in.source) cpu.attribution = echo.source();
    cpu.regs.setSp(0x2000_0300);
    if (in.ns) cpu.banked.switchTo(&cpu.regs, .non_secure);
    if (in.unprivileged) cpu.regs.control |= cpu_ns.regs.control_bits.npriv;
    const rn: u4 = @truncate(in.hw1);
    const rd: u4 = @truncate(in.hw2 >> 8);
    cpu.regs.set(rd, vectors.rd_in);
    if (rn == 13) cpu.regs.setSp(vectors.target) else if (rn != 15) cpu.regs.set(rn, vectors.target);
    const instr: cpu_ns.instr.Instr = .{ .address = fixture.code, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.tt.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch return vectors.none;
    return .{ .rd = cpu.regs.get(rd), .asked = echo.asked };
}

test "tt matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("tt", name);
}
