//! Covers src/chip/core/cpu/conformance/base/sg_vectors.zig: each vector runs
//! through the `sg` group over the exception tests' RAM, with a fixed-state
//! attribution source when the vector asks for one.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.sg_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const Attribution = cpu_ns.cpu.attribution.Attribution;
const State = cpu_ns.cpu.attribution.State;
const fixture = @import("../../exception/ram.zig");

/// Answers one state for every address.
const Fixed = struct {
    state: State,

    fn of(context: *anyopaque, address: u32) State {
        _ = address;
        const self: *Fixed = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn source(self: *Fixed) Attribution {
        return .{ .context = self, .stateFn = of };
    }
};

fn faultOf(err: anyerror) vectors.Fault {
    return if (err == error.InvalidEntry) .invalid_entry else .other;
}

fn observe(cpu: *const Cpu, ended: vectors.Fault) vectors.Out {
    return .{
        .fault = ended,
        .secure = cpu.banked.current == .secure,
        .lr = cpu.regs.get(14),
        .sp = cpu.regs.sp(),
    };
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    var fixed: Fixed = .{ .state = .secure };
    switch (in.attr) {
        .none => {},
        .secure => fixed.state = .secure,
        .non_secure => fixed.state = .non_secure,
        .callable => fixed.state = .callable,
    }
    if (in.attr != .none) cpu.attribution = fixed.source();
    cpu.regs.setSp(vectors.s_sp);
    if (in.ns) {
        cpu.banked.switchTo(&cpu.regs, .non_secure);
        cpu.regs.setSp(vectors.ns_sp);
    }
    cpu.regs.set(14, in.lr);
    const instr: cpu_ns.instr.Instr = .{ .address = fixture.code, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const none: vectors.Out = .{ .claimed = false, .secure = false, .lr = 0, .sp = 0 };
    const exec = cpu_ns.ops.sg.group.decode(instr) orelse return none;
    exec(&cpu, instr) catch |err| return observe(&cpu, faultOf(err));
    return observe(&cpu, .none);
}

test "sg matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("sg", name);
}
