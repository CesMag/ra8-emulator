//! FPU corpus image (RA8EMU-143): single- and double-precision arithmetic
//! on the Cortex-M85, each result stored to SRAM beside the FPSCR it left.
//! Built freestanding with Zig 0.17.0; see README.md for the command.

const results: [*]volatile u32 = @ptrFromInt(0x2200_0100);

const f32_pairs = [_][2]u32{
    .{ 0x3F80_0000, 0x4040_0000 }, // 1.0, 3.0
    .{ 0x3DCC_CCCD, 0x3E4C_CCCD }, // 0.1, 0.2
    .{ 0xC2F6_E979, 0x3F00_0000 }, // -123.456, 0.5
    .{ 0x4049_0FDB, 0x0000_0000 }, // pi, +0.0
    .{ 0xBF80_0000, 0x4000_0000 }, // -1.0, 2.0
};

const f64_pairs = [_][2]u64{
    .{ 0x3FF0_0000_0000_0000, 0x4008_0000_0000_0000 },
    .{ 0x3FB9_9999_9999_999A, 0x3FC9_9999_9999_999A },
    .{ 0xC05E_DD2F_1A9F_BE77, 0x3FE0_0000_0000_0000 },
    .{ 0x4009_21FB_5444_2D18, 0x0000_0000_0000_0000 },
    .{ 0xBFF0_0000_0000_0000, 0x4000_0000_0000_0000 },
};

var slot: usize = 0;

fn clearFlags() void {
    asm volatile ("vmsr fpscr, %[v]"
        :
        : [v] "r" (@as(u32, 0)),
        : .{ .memory = true });
}

fn store(word: u32) void {
    results[slot] = word;
    slot += 1;
}

fn storeFpscr() void {
    store(asm volatile ("vmrs %[v], fpscr"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true }));
}

fn single(a: f32, b: f32) void {
    const ops = [_]*const fn (f32, f32) f32{ add32, sub32, mul32, div32, sqrt32, fma32 };
    for (ops) |op| {
        clearFlags();
        store(@bitCast(op(a, b)));
        storeFpscr();
    }
}

fn double(a: f64, b: f64) void {
    const ops = [_]*const fn (f64, f64) f64{ add64, sub64, mul64, div64, sqrt64, fma64 };
    for (ops) |op| {
        clearFlags();
        const bits: u64 = @bitCast(op(a, b));
        store(@truncate(bits));
        store(@truncate(bits >> 32));
        storeFpscr();
    }
}

fn add32(a: f32, b: f32) f32 {
    return a + b;
}
fn sub32(a: f32, b: f32) f32 {
    return a - b;
}
fn mul32(a: f32, b: f32) f32 {
    return a * b;
}
fn div32(a: f32, b: f32) f32 {
    return a / b;
}
fn sqrt32(a: f32, _: f32) f32 {
    return @sqrt(a);
}
fn fma32(a: f32, b: f32) f32 {
    return @mulAdd(f32, a, b, a);
}
fn add64(a: f64, b: f64) f64 {
    return a + b;
}
fn sub64(a: f64, b: f64) f64 {
    return a - b;
}
fn mul64(a: f64, b: f64) f64 {
    return a * b;
}
fn div64(a: f64, b: f64) f64 {
    return a / b;
}
fn sqrt64(a: f64, _: f64) f64 {
    return @sqrt(a);
}
fn fma64(a: f64, b: f64) f64 {
    return @mulAdd(f64, a, b, a);
}

export fn main() void {
    slot = 0;
    const p32: *const volatile [f32_pairs.len][2]u32 = &f32_pairs;
    for (p32) |pair| single(@bitCast(pair[0]), @bitCast(pair[1]));
    const p64: *const volatile [f64_pairs.len][2]u64 = &f64_pairs;
    for (p64) |pair| double(@bitCast(pair[0]), @bitCast(pair[1]));
    store(0x0F9C_0DE5);
}
