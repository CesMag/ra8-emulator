//! Covers src/chip/core/cpu/exception/target.zig.
const std = @import("std");
const ra8 = @import("ra8");
const target = ra8.chip.core.cpu.exception.target;
const fixture = @import("ram.zig");

const aircr: u32 = 0xE000_ED0C;

test "from Secure every exception stays Secure" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    for ([_]u9{ 2, 3, 5, 7, 11, 14, 15, 16, 60 }) |number| try std.testing.expect(target.secure(&cpu, number));
}

test "from Non-secure SecureFault, HardFault, NMI and BusFault go Secure" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    for ([_]u9{ 2, 3, 5, 7 }) |number| try std.testing.expect(target.secure(&cpu, number));
    for ([_]u9{ 4, 6, 11, 12, 16, 60 }) |number| try std.testing.expect(!target.secure(&cpu, number));
    // PendSV and SysTick from the Secure copy stay Secure (RA8EMU-439,
    // RA8EMU-154).
    for ([_]u9{ 14, 15 }) |number| try std.testing.expect(target.secure(&cpu, number));
}

test "BFHFNMINS hands HardFault, NMI and BusFault to Non-secure" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    ram.putWord(aircr, target.bfhfnmins);
    for ([_]u9{ 2, 3, 5 }) |number| try std.testing.expect(!target.secure(&cpu, number));
    try std.testing.expect(target.secure(&cpu, 7));
}

test "SysTick and PendSV from the Non-secure copy go Non-secure from Secure" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.entering_non_secure = true;
    for ([_]u9{ 14, 15 }) |number| try std.testing.expect(!target.secure(&cpu, number));
    for ([_]u9{ 3, 11, 16 }) |number| try std.testing.expect(target.secure(&cpu, number));
}
