const std = @import("std");
const probe = @import("cli_app").probe_ctl;

test "probe ctl parses capability and hardware actions" {
    const capabilities = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "capabilities" };
    const registers = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "registers" };
    const halt = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "halt" };
    const resume_args = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "resume" };
    const step_args = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "step" };
    try std.testing.expectEqual(probe.Action.capabilities, (try probe.parse(&capabilities)).action);
    try std.testing.expectEqual(probe.Action.registers, (try probe.parse(&registers)).action);
    try std.testing.expectEqual(probe.Action.halt, (try probe.parse(&halt)).action);
    try std.testing.expectEqual(probe.Action.cont, (try probe.parse(&resume_args)).action);
    try std.testing.expectEqual(probe.Action.step, (try probe.parse(&step_args)).action);
}

test "probe ctl bounds memory reads" {
    const valid = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "read", "0x02000000", "8" };
    const too_long = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "read", "0x02000000", "257" };
    const request = try probe.parse(&valid);
    try std.testing.expectEqual(@as(u32, 0x02000000), request.address);
    try std.testing.expectEqual(@as(u16, 8), request.length);
    try std.testing.expectError(error.BadLength, probe.parse(&too_long));
}
