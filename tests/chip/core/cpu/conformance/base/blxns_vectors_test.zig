//! Covers src/chip/core/cpu/conformance/base/blxns_vectors.zig: each vector runs
//! through the `blxns` group on a bare core whose bus holds only VTOR_NS,
//! the first word of the Non-secure vector table and the 8 bytes below SP.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.blxns_vectors;
const cpu_ns = ra8.chip.core.cpu;
const bus = cpu_ns.bus;
const vtor_ns = ra8.chip.core.memmap.scb.vtor_ns;

const Table = struct {
    in: vectors.In,

    fn view(self: *Table) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Table = @ptrCast(@alignCast(ctx));
        const value = if (address == vtor_ns)
            self.in.vtor_ns
        else if (self.in.table_mapped and self.in.vtor_ns != 0 and address == self.in.vtor_ns)
            self.in.ns_sp
        else
            return bus.Error.Unmapped;
        if (into.len != 4) return bus.Error.Unmapped;
        std.mem.writeInt(u32, into[0..4], value, .little);
    }

    /// Only the return frame a Non-secure call pushes below SP lands.
    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Table = @ptrCast(@alignCast(ctx));
        if (from.len != 4 or address < self.in.sp -% 8 or address >= self.in.sp) return bus.Error.Unmapped;
    }
};

fn run(in: vectors.In) vectors.Out {
    var table: Table = .{ .in = in };
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = table.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.setSp(in.sp);
    cpu.regs.set(in.rm, in.target);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.blxns.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch return .{ .claimed = false, .pc = 1, .lr = 1, .sp = 1 };
    return .{ .pc = cpu.regs.pc, .lr = cpu.regs.lr, .sp = cpu.regs.sp(), .secure = cpu.banked.current == .secure };
}

test "blxns matches the model" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("blxns", name);
}
