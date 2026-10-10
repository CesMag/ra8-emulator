//! Covers src/chip/core/cpu/fpu/cpacr.zig against the Arm ARM (DDI0553)
//! IsCPEnabled() pseudocode, row by row.
const std = @import("std");
const ra8 = @import("ra8");
const cpacr = ra8.chip.core.cpu.fpu.cpacr;

const Row = struct {
    cpacr: u32,
    nsacr: u32 = 0,
    privileged: bool,
    secure: bool = true,
    enabled: bool,
    to_secure: bool = false,
};

fn field(a: u2) u32 {
    return @as(u32, a) << 20;
}

const rows = [_]Row{
    // Secure: CPACR alone decides.
    .{ .cpacr = field(0b00), .privileged = true, .enabled = false },
    .{ .cpacr = field(0b00), .privileged = false, .enabled = false },
    .{ .cpacr = field(0b01), .privileged = true, .enabled = true },
    .{ .cpacr = field(0b01), .privileged = false, .enabled = false },
    .{ .cpacr = field(0b10), .privileged = true, .enabled = false },
    .{ .cpacr = field(0b11), .privileged = true, .enabled = true },
    .{ .cpacr = field(0b11), .privileged = false, .enabled = true },
    // Non-secure without NSACR.CP10: refused to Secure whatever CPACR says.
    .{ .cpacr = field(0b11), .privileged = true, .secure = false, .enabled = false, .to_secure = true },
    .{ .cpacr = field(0b00), .privileged = true, .secure = false, .enabled = false, .to_secure = true },
    // Non-secure with NSACR.CP10: CPACR_NS decides, faults stay Non-secure.
    .{ .cpacr = field(0b11), .nsacr = 1 << 10, .privileged = false, .secure = false, .enabled = true },
    .{ .cpacr = field(0b01), .nsacr = 1 << 10, .privileged = false, .secure = false, .enabled = false },
    .{ .cpacr = field(0b01), .nsacr = 1 << 10, .privileged = true, .secure = false, .enabled = true },
    .{ .cpacr = field(0b00), .nsacr = 1 << 10, .privileged = true, .secure = false, .enabled = false },
};

test "IsCPEnabled(10) follows the pseudocode for every CPACR, NSACR and mode" {
    for (rows, 0..) |row, i| {
        const got = cpacr.check(.{ .cpacr = row.cpacr, .nsacr = row.nsacr, .privileged = row.privileged, .secure = row.secure });
        errdefer std.debug.print("row {d}\n", .{i});
        try std.testing.expectEqual(row.enabled, got.enabled);
        try std.testing.expectEqual(row.to_secure, got.to_secure);
    }
}

test "only CP10 is read: CP11 and the other fields change nothing" {
    const noise: u32 = 0xFFCF_FFFF; // every field but CP10
    try std.testing.expect(!cpacr.check(.{ .cpacr = noise, .privileged = true }).enabled);
    try std.testing.expect(cpacr.check(.{ .cpacr = field(0b11), .privileged = false }).enabled);
    try std.testing.expectEqual(cpacr.Access.full, cpacr.access(cpacr.full_access));
}

test "reset CPACR leaves the FPU off" {
    try std.testing.expectEqual(cpacr.Access.none, cpacr.access(0));
    try std.testing.expect(!cpacr.check(.{ .cpacr = 0, .privileged = true }).enabled);
}
