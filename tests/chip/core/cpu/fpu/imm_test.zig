const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;

/// The value the Arm ARM gives for imm8 = a:b:cd:efgh, computed in float
/// arithmetic as an independent check on the bit assembly.
fn value(imm8: u8) f64 {
    const sign: f64 = if (imm8 >> 7 == 1) -1 else 1;
    const b: i32 = imm8 >> 6 & 1;
    const cd: i32 = imm8 >> 4 & 3;
    const scale: i32 = ((b ^ 1) << 2 | cd) - 3;
    const frac: f64 = @floatFromInt(16 + @as(u32, imm8 & 0xF));
    return sign * frac / 16 * std.math.pow(f64, 2, @floatFromInt(scale));
}

test "all 256 single immediates match the formula" {
    var imm8: u32 = 0;
    while (imm8 < 256) : (imm8 += 1) {
        const want: f32 = @floatCast(value(@intCast(imm8)));
        try std.testing.expectEqual(@as(u32, @bitCast(want)), fpu.imm.expandImm(fpu.format.single, @intCast(imm8)));
    }
}

test "all 256 double immediates match the formula" {
    var imm8: u32 = 0;
    while (imm8 < 256) : (imm8 += 1) {
        const want = value(@intCast(imm8));
        try std.testing.expectEqual(@as(u64, @bitCast(want)), fpu.imm.expandImm(fpu.format.double, @intCast(imm8)));
    }
}
