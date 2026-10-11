//! FPU corpus image (RA8EMU-143): VCMP, VCMPE, VMAXNM and VMINNM in single
//! and double precision on the Cortex-M85, over ordered pairs, signed zeros,
//! infinities, subnormals and quiet and signalling NaNs. Each compare stores
//! FPSCR (NZCV and flags); each min/max stores its result and the flags.
//! Built freestanding with Zig 0.17.0; see README.md for the command.

const results: [*]volatile u32 = @ptrFromInt(0x2200_0100);
/// NZCV and the cumulative exception flags.
const fpscr_mask: u32 = 0xF000_009F;

const p32 = [_][2]u32{ .{ 0x3F800000, 0x40000000 }, .{ 0x40000000, 0x3F800000 }, .{ 0x3F800000, 0x3F800000 }, .{ 0x00000000, 0x80000000 }, .{ 0x80000000, 0x00000000 }, .{ 0x7FC00000, 0x3F800000 }, .{ 0x3F800000, 0x7FC00000 }, .{ 0x7F800001, 0x3F800000 }, .{ 0x3F800000, 0x7F800001 }, .{ 0x7FC00000, 0x7F800001 }, .{ 0x7FC00001, 0xFFC00002 }, .{ 0xFF800000, 0x7F800000 }, .{ 0x00000001, 0x80000001 } };
const p64 = [_][2]u64{ .{ 0x3FF0000000000000, 0x4000000000000000 }, .{ 0x4000000000000000, 0x3FF0000000000000 }, .{ 0x3FF0000000000000, 0x3FF0000000000000 }, .{ 0x0000000000000000, 0x8000000000000000 }, .{ 0x8000000000000000, 0x0000000000000000 }, .{ 0x7FF8000000000000, 0x3FF0000000000000 }, .{ 0x3FF0000000000000, 0x7FF8000000000000 }, .{ 0x7FF0000000000001, 0x3FF0000000000000 }, .{ 0x3FF0000000000000, 0x7FF0000000000001 }, .{ 0x7FF8000000000000, 0x7FF0000000000001 }, .{ 0x7FF8000000000001, 0xFFF8000000000002 }, .{ 0xFFF0000000000000, 0x7FF0000000000000 }, .{ 0x0000000000000001, 0x8000000000000001 } };

var slot: usize = 0;

fn store(word: u32) void {
    results[slot] = word;
    slot += 1;
}

fn fpscr() void {
    store(asm volatile ("vmrs %[v], fpscr"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true }) & fpscr_mask);
}

fn clear() void {
    asm volatile ("vmsr fpscr, %[v]"
        :
        : [v] "r" (@as(u32, 0)),
        : .{ .memory = true });
}

/// Runs a two-operand single-precision op on s0, s1 and stores s0 when the
/// op writes it, then FPSCR.
fn single(comptime insn: []const u8, comptime writes: bool, a: u32, b: u32) void {
    clear();
    const r = asm volatile ("vmov s0, %[a]\nvmov s1, %[b]\n" ++ insn ++ "\nvmov %[r], s0"
        : [r] "=r" (-> u32),
        : [a] "r" (a),
          [b] "r" (b),
        : .{ .s0 = true, .s1 = true, .memory = true });
    if (writes) store(r);
    fpscr();
}

/// The double-precision twin of `single`, on d0 and d1.
fn double(comptime insn: []const u8, comptime writes: bool, a: u64, b: u64) void {
    clear();
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("vmov d0, %[al], %[ah]\nvmov d1, %[bl], %[bh]\n" ++ insn ++ "\nvmov %[lo], %[hi], d0"
        : [lo] "=r" (lo),
          [hi] "=r" (hi),
        : [al] "r" (@as(u32, @truncate(a))),
          [ah] "r" (@as(u32, @truncate(a >> 32))),
          [bl] "r" (@as(u32, @truncate(b))),
          [bh] "r" (@as(u32, @truncate(b >> 32))),
        : .{ .d0 = true, .d1 = true, .memory = true });
    if (writes) {
        store(lo);
        store(hi);
    }
    fpscr();
}

fn pair32(a: u32, b: u32) void {
    single("vcmp.f32 s0, s1", false, a, b);
    single("vcmpe.f32 s0, s1", false, a, b);
    single("vcmp.f32 s0, #0", false, a, b);
    single("vcmpe.f32 s0, #0", false, a, b);
    single("vmaxnm.f32 s0, s0, s1", true, a, b);
    single("vminnm.f32 s0, s0, s1", true, a, b);
}

fn pair64(a: u64, b: u64) void {
    double("vcmp.f64 d0, d1", false, a, b);
    double("vcmpe.f64 d0, d1", false, a, b);
    double("vcmp.f64 d0, #0", false, a, b);
    double("vcmpe.f64 d0, #0", false, a, b);
    double("vmaxnm.f64 d0, d0, d1", true, a, b);
    double("vminnm.f64 d0, d0, d1", true, a, b);
}

export fn main() void {
    slot = 0;
    const s: *const volatile [p32.len][2]u32 = &p32;
    for (s) |p| pair32(p[0], p[1]);
    const d: *const volatile [p64.len][2]u64 = &p64;
    for (d) |p| pair64(p[0], p[1]);
    store(0x0F9C_0DE5);
}
