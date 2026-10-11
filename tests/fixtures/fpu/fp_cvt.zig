//! FPU corpus image (RA8EMU-143): float to integer, integer to float,
//! precision changes and round-to-integral on the Cortex-M85. Each result
//! goes to SRAM beside the FPSCR flags it raised. Built freestanding with
//! Zig 0.17.0; see README.md for the command.

const results: [*]volatile u32 = @ptrFromInt(0x2200_0100);
/// Only the cumulative exception flags (IOC, DZC, OFC, UFC, IXC, IDC).
const flag_mask: u32 = 0x9F;

const f32_in = [_]u32{ 0x3FC00000, 0xBFC00000, 0x40200000, 0xBECCCCCD, 0x4F32D05E, 0xCF32D05E, 0x4F832156, 0x7FC00000, 0x477FE000, 0x4788B800, 0x3727C5AC, 0x3DCCCCCD };
const f64_in = [_]u64{ 0x37A16C262777579C, 0x48078287F49C4A1D, 0xC004000000000000, 0x3FB999999999999A, 0x41E0000000000000, 0x7FF8000000000000 };
const f16_in = [_]u32{ 0x3C00, 0x7BFF, 0x0001, 0x7C00, 0xFE00, 0x7D00 };

var slot: usize = 0;

fn store(word: u32) void {
    results[slot] = word;
    slot += 1;
}

fn flags() void {
    store(asm volatile ("vmrs %[v], fpscr"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true }) & flag_mask);
}

fn clear() void {
    asm volatile ("vmsr fpscr, %[v]"
        :
        : [v] "r" (@as(u32, 0)),
        : .{ .memory = true });
}

/// Runs one single-register op on s0 and stores its result and flags.
fn single(comptime insn: []const u8, x: u32, keep: u32) void {
    clear();
    store(asm volatile ("vmov s0, %[x]\n" ++ insn ++ "\nvmov %[r], s0"
        : [r] "=r" (-> u32),
        : [x] "r" (x),
        : .{ .s0 = true, .memory = true }) & keep);
    flags();
}

fn widen(x: u32) void {
    clear();
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("vmov s0, %[x]\nvcvt.f64.f32 d1, s0\nvmov %[lo], %[hi], d1"
        : [lo] "=r" (lo),
          [hi] "=r" (hi),
        : [x] "r" (x),
        : .{ .s0 = true, .d1 = true, .memory = true });
    store(lo);
    store(hi);
    flags();
}

/// Runs one op reading d1 and writing s0, then stores s0 and the flags.
fn fromDouble(comptime insn: []const u8, x: u64) void {
    clear();
    store(asm volatile ("vmov d1, %[lo], %[hi]\n" ++ insn ++ "\nvmov %[r], s0"
        : [r] "=r" (-> u32),
        : [lo] "r" (@as(u32, @truncate(x))),
          [hi] "r" (@as(u32, @truncate(x >> 32))),
        : .{ .s0 = true, .d1 = true, .memory = true }));
    flags();
}

fn toDouble(x: u32) void {
    clear();
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("vmov s0, %[x]\nvcvt.f64.s32 d1, s0\nvmov %[lo], %[hi], d1"
        : [lo] "=r" (lo),
          [hi] "=r" (hi),
        : [x] "r" (x),
        : .{ .s0 = true, .d1 = true, .memory = true });
    store(lo);
    store(hi);
    flags();
}

fn fromSingle(x: u32) void {
    const all: u32 = 0xFFFF_FFFF;
    single("vcvt.s32.f32 s0, s0", x, all);
    single("vcvt.u32.f32 s0, s0", x, all);
    single("vcvtr.s32.f32 s0, s0", x, all);
    single("vcvta.s32.f32 s0, s0", x, all);
    single("vcvtn.s32.f32 s0, s0", x, all);
    single("vcvtp.s32.f32 s0, s0", x, all);
    single("vcvtm.s32.f32 s0, s0", x, all);
    widen(x);
    single("vcvtb.f16.f32 s0, s0", x, 0xFFFF);
    single("vrinta.f32 s0, s0", x, all);
    single("vrintn.f32 s0, s0", x, all);
    single("vrintp.f32 s0, s0", x, all);
    single("vrintm.f32 s0, s0", x, all);
    single("vrintz.f32 s0, s0", x, all);
    single("vrintx.f32 s0, s0", x, all);
    single("vrintr.f32 s0, s0", x, all);
    single("vcvt.f32.s32 s0, s0", x, all);
    single("vcvt.f32.u32 s0, s0", x, all);
}

fn fromDoubleAll(x: u64) void {
    fromDouble("vcvt.f32.f64 s0, d1", x);
    fromDouble("vcvt.s32.f64 s0, d1", x);
    fromDouble("vcvt.u32.f64 s0, d1", x);
    toDouble(@truncate(x));
}

export fn main() void {
    slot = 0;
    const s: *const volatile [f32_in.len]u32 = &f32_in;
    for (s) |x| fromSingle(x);
    const d: *const volatile [f64_in.len]u64 = &f64_in;
    for (d) |x| fromDoubleAll(x);
    const h: *const volatile [f16_in.len]u32 = &f16_in;
    for (h) |x| single("vcvtb.f32.f16 s0, s0", x, 0xFFFF_FFFF);
    store(0x0F9C_0DE5);
}
