//! Covers src/interfaces/cli/report/json/regs.zig: the `--dump-regs` rows
//! of `--report json` read the Zig core's registers on a `--cpu zig` run.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_regs = cli_app.report.json.run.json_dumps.json_regs;
const Regs = ra8.chip.core.cpu.boot.Regs;

test "a zig reader reads the core's registers, not reset values" {
    var regs: Regs = .{ .pc = 0x0200_1092, .lr = 0x0200_0645, .msp = 0x220F_FED8 };
    regs.low[0] = 500;
    regs.low[12] = 7;
    const from: json_regs.Reader = .{ .zig = &regs };
    try std.testing.expectEqual(@as(?u32, 500), from.register(.r0));
    try std.testing.expectEqual(@as(?u32, 7), from.register(.r12));
    try std.testing.expectEqual(@as(?u32, 0x220F_FED8), from.register(.sp));
    try std.testing.expectEqual(@as(?u32, 0x0200_0645), from.register(.lr));
    try std.testing.expectEqual(@as(?u32, 0x0200_1092), from.register(.pc));
}

test "a register the zig file does not name reads null" {
    const regs: Regs = .{};
    const from: json_regs.Reader = .{ .zig = &regs };
    try std.testing.expectEqual(@as(?u32, null), from.register(.msp));
}
