//! DHCSR, DCRSR and DCRDR as firmware sees them.
const std = @import("std");
const ra8 = @import("ra8");
const dcb = ra8.chip.periph.dcb;
const bits = dcb.dhcsr_bits;

const keyed: u32 = bits.key << bits.key_shift;

test "DHCSR reads C_DEBUGEN only once a debugger attached, with S_REGRDY" {
    var unit = dcb.Dcb{};
    try std.testing.expectEqual(@as(?u32, bits.s_regrdy), unit.peek(dcb.offsets.dhcsr));
    unit.attachDebugger();
    try std.testing.expectEqual(@as(?u32, bits.s_regrdy | bits.c_debugen), unit.peek(dcb.offsets.dhcsr));
    try std.testing.expectEqual(@as(?u32, null), unit.peek(dcb.span));
}

test "a keyed C_HALT asks for a halt once, and an unkeyed one is dropped" {
    var unit = dcb.Dcb{};
    unit.attachDebugger();
    try std.testing.expect(unit.write(dcb.offsets.dhcsr, bits.c_halt | bits.c_debugen));
    try std.testing.expect(!unit.takeHalt());
    _ = unit.write(dcb.offsets.dhcsr, keyed | bits.c_halt | bits.c_debugen | bits.c_maskints);
    try std.testing.expect(unit.takeHalt());
    try std.testing.expect(!unit.takeHalt());
    try std.testing.expectEqual(@as(?u32, bits.s_regrdy | bits.c_debugen | bits.c_maskints), unit.peek(dcb.offsets.dhcsr));
}

test "without a debugger, firmware cannot halt or set C_DEBUGEN" {
    var unit = dcb.Dcb{};
    _ = unit.write(dcb.offsets.dhcsr, keyed | bits.c_halt | bits.c_debugen);
    try std.testing.expect(!unit.takeHalt());
    try std.testing.expectEqual(@as(?u32, bits.s_regrdy), unit.peek(dcb.offsets.dhcsr));
}

test "DCRDR holds a word and DCRSR reads zero" {
    var unit = dcb.Dcb{};
    try std.testing.expect(unit.write(dcb.offsets.dcrdr, 0xCAFE_F00D));
    try std.testing.expect(unit.write(dcb.offsets.dcrsr, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(?u32, 0xCAFE_F00D), unit.peek(dcb.offsets.dcrdr));
    try std.testing.expectEqual(@as(?u32, 0), unit.peek(dcb.offsets.dcrsr));
    try std.testing.expectEqual(dcb.dcrsr_bits.regsel | dcb.dcrsr_bits.regwnr, unit.selector);
}

test "DFSR latches debug events and a write of one clears each bit" {
    var unit = dcb.Dcb{};
    unit.latch(dcb.dfsr_bits.bkpt);
    unit.latch(dcb.dfsr_bits.dwttrap);
    try std.testing.expectEqual(dcb.dfsr_bits.bkpt | dcb.dfsr_bits.dwttrap, unit.dfsr);
    unit.clearStatus(dcb.dfsr_bits.bkpt);
    try std.testing.expectEqual(dcb.dfsr_bits.dwttrap, unit.dfsr);
}

test "C_MASKINTS masks interrupts only with C_DEBUGEN set" {
    try std.testing.expect(dcb.masksInterrupts(bits.c_debugen | bits.c_maskints | bits.s_regrdy));
    try std.testing.expect(!dcb.masksInterrupts(bits.c_maskints));
    try std.testing.expect(!dcb.masksInterrupts(bits.c_debugen));
}
