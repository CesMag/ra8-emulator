//! The DWT comparator registers and the matches they make.
const std = @import("std");
const ra8 = @import("ra8");
const dwt = ra8.chip.periph.dwt;

const word_size: u32 = 2 << dwt.function_bits.size_shift;
const halts: u32 = dwt.function_bits.action_debug << dwt.function_bits.action_shift;

fn function(n: u32) u32 {
    return dwt.offsets.function0 + n * dwt.offsets.stride;
}

test "only the comparator registers are claimed, not CTRL or CYCCNT" {
    var unit = dwt.Dwt{};
    try std.testing.expect(!unit.write(0x000, 1));
    try std.testing.expect(!unit.write(0x004, 1));
    try std.testing.expect(!unit.write(dwt.offsets.comp0 + 4, 1));
    try std.testing.expect(!unit.write(dwt.limits.end, 1));
    try std.testing.expect(unit.write(dwt.offsets.comp0 + dwt.offsets.stride, 0x2000_0040));
    try std.testing.expectEqual(@as(?u32, 0x2000_0040), unit.peek(dwt.offsets.comp0 + dwt.offsets.stride));
}

test "FUNCTION keeps MATCH, ACTION and DATAVSIZE and drops read-only bits" {
    var unit = dwt.Dwt{};
    try std.testing.expect(unit.write(function(0), 0xFFFF_FFFF));
    const id0 = dwt.id.cycles_instruction_data << dwt.function_bits.id_shift;
    try std.testing.expectEqual(@as(?u32, id0 | dwt.function_bits.writable), unit.peek(function(0)));
}

test "a halting data write comparator matches a store and sets MATCHED" {
    var unit = dwt.Dwt{ .trcena = true };
    _ = unit.write(dwt.offsets.comp0, 0x2000_1000);
    _ = unit.write(function(0), dwt.match.data_write | halts | word_size);
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_1000, 4, .read, null));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_1004, 4, .write, null));
    try std.testing.expectEqual(@as(?usize, 0), unit.access(0x2000_1002, 1, .write, null));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched != 0);
}

test "a trigger-only comparator sets MATCHED without halting, and a read clears it" {
    var unit = dwt.Dwt{ .trcena = true };
    _ = unit.write(dwt.offsets.comp0, 0x2000_1000);
    _ = unit.write(function(0), dwt.match.data | word_size);
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_1000, 4, .read, null));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched != 0);
    unit.loaded(function(0));
    try std.testing.expectEqual(@as(u32, 0), unit.peek(function(0)).? & dwt.function_bits.matched);
}

test "an instruction address comparator matches the fetch, Thumb bit or not" {
    var unit = dwt.Dwt{ .trcena = true };
    _ = unit.write(dwt.offsets.comp0, 0x0000_0200);
    _ = unit.write(function(0), dwt.match.instruction | halts | (1 << dwt.function_bits.size_shift));
    try std.testing.expectEqual(@as(?usize, null), unit.matchesPc(0x202));
    try std.testing.expectEqual(@as(?usize, 0), unit.matchesPc(0x201));
}

test "with DEMCR.TRCENA clear nothing matches and MATCHED stays clear" {
    var unit = dwt.Dwt{};
    _ = unit.write(dwt.offsets.comp0, 0x2000_1000);
    _ = unit.write(function(0), dwt.match.data | halts | word_size);
    _ = unit.write(dwt.offsets.comp0 + dwt.offsets.stride, 0x0000_0200);
    _ = unit.write(function(1), dwt.match.instruction | halts | (1 << dwt.function_bits.size_shift));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_1000, 4, .write, null));
    try std.testing.expectEqual(@as(?usize, null), unit.matchesPc(0x200));
    try std.testing.expectEqual(@as(u32, 0), unit.peek(function(0)).? & dwt.function_bits.matched);
    unit.trcena = true;
    try std.testing.expectEqual(@as(?usize, 0), unit.access(0x2000_1000, 4, .write, null));
    try std.testing.expectEqual(@as(?usize, 1), unit.matchesPc(0x200));
}

test "FUNCTION.ID is read-only: comparator 0 adds Cycle Counter, odd comparators take values" {
    var unit = dwt.Dwt{};
    const shift = dwt.function_bits.id_shift;
    try std.testing.expectEqual(@as(?u32, dwt.id.cycles_instruction_data << shift), unit.peek(function(0)));
    for (1..dwt.limits.comparators) |n| {
        const expected = if (n % 2 == 1) dwt.id.instruction_data_values else dwt.id.instruction_data_limits;
        try std.testing.expectEqual(@as(?u32, expected << shift), unit.peek(function(@intCast(n))));
    }
    _ = unit.write(function(1), 0);
    try std.testing.expectEqual(@as(?u32, dwt.id.instruction_data_values << shift), unit.peek(function(1)));
}

const one_byte: u32 = 0;
const halfword: u32 = 1 << dwt.function_bits.size_shift;

fn arm(unit: *dwt.Dwt, n: u32, comp: u32, function_value: u32) void {
    _ = unit.write(dwt.offsets.comp0 + n * dwt.offsets.stride, comp);
    _ = unit.write(function(n), function_value);
}

test "an Instruction Address Limit makes an inclusive range reported on the lower comparator" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 0, 0x100, dwt.match.instruction | halts | halfword);
    arm(&unit, 1, 0x10E, dwt.match.instruction_limit | halfword);
    try std.testing.expectEqual(@as(?usize, 0), unit.matchesPc(0x100));
    try std.testing.expectEqual(@as(?usize, 0), unit.matchesPc(0x108));
    try std.testing.expectEqual(@as(?usize, 0), unit.matchesPc(0x10F));
    try std.testing.expectEqual(@as(?usize, null), unit.matchesPc(0x110));
    try std.testing.expectEqual(@as(?usize, null), unit.matchesPc(0x0FE));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched != 0);
    try std.testing.expectEqual(@as(u32, 0), unit.peek(function(1)).? & dwt.function_bits.matched);
}

test "a Data Address Limit range keeps the lower comparator's read or write filter" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 2, 0x2000_0000, dwt.match.data_write | halts | one_byte);
    arm(&unit, 3, 0x2000_00FF, dwt.match.data_limit | one_byte);
    try std.testing.expectEqual(@as(?usize, 2), unit.access(0x2000_0080, 4, .write, null));
    try std.testing.expectEqual(@as(?usize, 2), unit.access(0x2000_00FF, 1, .write, null));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0080, 4, .read, null));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0100, 4, .write, null));
    try std.testing.expectEqual(@as(?usize, null), unit.matchesPc(0x2000_0080));
}

test "a limit with nothing to pair with matches nothing" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 0, 0x2000_00FF, dwt.match.data_limit | halts);
    arm(&unit, 2, 0x300, dwt.match.instruction_limit | halts | halfword);
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 4, .write, null));
    try std.testing.expectEqual(@as(?usize, null), unit.matchesPc(0x200));
    try std.testing.expectEqual(@as(?usize, null), unit.matchesPc(0x300));
}

fn vmask(n: u32) u32 {
    return dwt.offsets.vmask0 + n * dwt.offsets.stride;
}

test "a Data Value comparator matches a store of its value, in the lanes DATAVSIZE picks" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 1, 0xCAFE_F00D, dwt.match.data_value_write | halts | word_size);
    try std.testing.expectEqual(@as(?usize, 1), unit.access(0x2000_0010, 4, .write, 0xCAFE_F00D));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0010, 4, .write, 0xCAFE_F00E));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0010, 4, .read, 0xCAFE_F00D));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0010, 4, .write, null));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0010, 2, .write, 0xF00D));
    try std.testing.expect(unit.peek(function(1)).? & dwt.function_bits.matched != 0);
}

test "a byte Data Value comparator matches any byte lane the access carries" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 3, 0x5A5A_5A5A, dwt.match.data_value | halts | one_byte);
    try std.testing.expectEqual(@as(?usize, 3), unit.access(0x2000_0000, 1, .write, 0x5A));
    try std.testing.expectEqual(@as(?usize, 3), unit.access(0x2000_0000, 4, .write, 0x0000_5A00));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 1, .write, 0x5A00));
}

test "DWT_VMASK masks bits out of the value compare and reads zero for other MATCH kinds" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 5, 0x0000_1200, dwt.match.data_value | halts | word_size);
    try std.testing.expect(unit.write(vmask(5), 0x0000_00FF));
    try std.testing.expectEqual(@as(?u32, 0xFF), unit.peek(vmask(5)));
    try std.testing.expectEqual(@as(?usize, 5), unit.access(0x2000_0000, 4, .write, 0x0000_12AB));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 4, .write, 0x0000_13AB));
    _ = unit.write(function(5), dwt.match.data | word_size);
    try std.testing.expectEqual(@as(?u32, 0), unit.peek(vmask(5)));
}

test "an even comparator does not take the value kinds" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 2, 0x0000_0042, dwt.match.data_value | halts | word_size);
    _ = unit.write(vmask(2), 0xFF);
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 4, .write, 0x42));
    try std.testing.expectEqual(@as(?u32, 0), unit.peek(vmask(2)));
}

test "Linked Data Value needs comparator n-1's address and reads the lane it picks" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 0, 0x2000_0002, dwt.match.data_write | one_byte);
    arm(&unit, 1, 0x7777_7777, dwt.match.linked_data_value | halts | one_byte);
    try std.testing.expectEqual(@as(?usize, 1), unit.access(0x2000_0000, 4, .write, 0x0077_0000));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 4, .write, 0x0000_0077));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0004, 4, .write, 0x0077_0000));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 4, .read, 0x0077_0000));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched != 0);
    try std.testing.expect(unit.peek(function(1)).? & dwt.function_bits.matched != 0);
}

test "Linked Data Value matches nothing when the DATAVSIZEs differ" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 2, 0x2000_0000, dwt.match.data | word_size);
    arm(&unit, 3, 0x0000_0042, dwt.match.linked_data_value | halts | one_byte);
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 4, .write, 0x42));
}

test "a read Data Value comparator matches the value a load brings back" {
    var unit = dwt.Dwt{ .trcena = true };
    arm(&unit, 1, 0x0000_ABCD, dwt.match.data_value_read | halts | (1 << dwt.function_bits.size_shift));
    try std.testing.expectEqual(@as(?usize, 1), unit.access(0x2000_0000, 2, .read, 0xABCD));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 2, .write, 0xABCD));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_0000, 2, .read, 0xABCE));
}

test "NUMCOMP is 8 on the Cortex-M85 and 4 on the Cortex-M33" {
    const cpuid = ra8.chip.periph.cpuid;
    try std.testing.expectEqual(@as(u4, 8), dwt.numcompOf(cpuid.cpu0));
    try std.testing.expectEqual(@as(u4, 4), dwt.numcompOf(cpuid.cpu1));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), dwt.ctrlReset(cpuid.cpu0));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), dwt.ctrlReset(cpuid.cpu1));
}

test "a DWT_CTRL store keeps NUMCOMP and the other bits it wrote" {
    const unit = dwt.Dwt{ .numcomp = 4 };
    try std.testing.expectEqual(@as(u32, 0x4000_0001), unit.ctrlWord(0x0000_0001));
    try std.testing.expectEqual(@as(u32, 0x4FFF_FFFF), unit.ctrlWord(0xFFFF_FFFF));
}

test "comparators past NUMCOMP read zero, ignore writes and never match" {
    var unit = dwt.Dwt{ .numcomp = 4, .trcena = true };
    const comp4 = dwt.offsets.comp0 + 4 * dwt.offsets.stride;
    try std.testing.expect(unit.write(comp4, 0x2000_1000));
    try std.testing.expect(unit.write(function(4), dwt.match.data_write | halts | word_size));
    try std.testing.expectEqual(@as(?u32, 0), unit.peek(comp4));
    try std.testing.expectEqual(@as(?u32, 0), unit.peek(function(4)));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_1000, 4, .write, null));
    _ = unit.write(dwt.offsets.comp0 + 3 * dwt.offsets.stride, 0x2000_1000);
    _ = unit.write(function(3), dwt.match.data_write | halts | word_size);
    try std.testing.expectEqual(@as(?usize, 3), unit.access(0x2000_1000, 4, .write, null));
}

const counts: u32 = dwt.match.cycle_counter | halts;

fn cycleUnit(value: u32, function0: u32) dwt.Dwt {
    var unit = dwt.Dwt{ .trcena = true };
    _ = unit.write(dwt.offsets.comp0, value);
    _ = unit.write(function(0), function0);
    return unit;
}

test "a Cycle Counter comparator matches a count that steps over its value" {
    var unit = cycleUnit(100, counts);
    try std.testing.expect(unit.watchesCycles());
    try std.testing.expectEqual(@as(?usize, null), unit.cycleCounted(50));
    try std.testing.expectEqual(@as(?usize, null), unit.cycleCounted(99));
    try std.testing.expectEqual(@as(?usize, 0), unit.cycleCounted(150));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched != 0);
    try std.testing.expectEqual(@as(?usize, null), unit.cycleCounted(200));
}

test "the first sighting of CYCCNT only primes the Cycle Counter comparator" {
    var unit = cycleUnit(100, counts);
    try std.testing.expectEqual(@as(?usize, null), unit.cycleCounted(500));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched == 0);
}

test "a Cycle Counter comparator matches across the counter wrapping" {
    var unit = cycleUnit(5, counts);
    _ = unit.cycleCounted(0xFFFF_FFF0);
    try std.testing.expectEqual(@as(?usize, 0), unit.cycleCounted(0x10));
}

test "a direct CYCCNT write is checked, and is not counted again" {
    var unit = cycleUnit(7, counts);
    try std.testing.expectEqual(@as(?usize, null), unit.cycleWritten(6));
    try std.testing.expectEqual(@as(?usize, 0), unit.cycleWritten(7));
    try std.testing.expectEqual(@as(?usize, null), unit.cycleCounted(7));
}

test "a trigger-only Cycle Counter match sets MATCHED without halting" {
    var unit = cycleUnit(10, dwt.match.cycle_counter);
    _ = unit.cycleWritten(0);
    try std.testing.expectEqual(@as(?usize, null), unit.cycleCounted(20));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched != 0);
}

test "only comparator 0 counts cycles, and only while TRCENA is set" {
    var off = cycleUnit(10, counts);
    off.trcena = false;
    _ = off.cycleWritten(0);
    try std.testing.expectEqual(@as(?usize, null), off.cycleCounted(20));
    var unit = dwt.Dwt{ .trcena = true };
    _ = unit.write(dwt.offsets.comp0 + dwt.offsets.stride, 10);
    _ = unit.write(function(1), counts);
    try std.testing.expect(!unit.watchesCycles());
}
