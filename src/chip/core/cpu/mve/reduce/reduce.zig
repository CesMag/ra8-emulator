//! MVE across-vector reductions from the Arm ARM (DDI0553) pseudocode
//! (RA8EMU-25). VADDV and VADDLV sum every lane into a 32-bit register or
//! a 64-bit register pair. VMLADAV and VMLALDAV sum the lane products of two
//! vectors. The X forms pair each lane of Qm with the other lane of its pair
//! in Qn, and the VMLSDAV forms subtract the odd-lane products. The A
//! forms start from the accumulator; pass 0 for the plain forms. The sum is
//! exact and then wraps to the destination width.
const qreg = @import("../qreg.zig");
const int = @import("../int/int.zig");
pub const minmax = @import("minmax/minmax.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

/// How a dual multiply-accumulate pairs and signs its products.
pub const Dual = struct { unsigned: bool = false, exchange: bool = false, subtract: bool = false };

fn sumLanes(a: u128, size: Size, unsigned: bool) i128 {
    var total: i128 = 0;
    for (0..qreg.lanes(size)) |k| {
        total += int.extend(qreg.elem(a, size, @intCast(k)), size, unsigned);
    }
    return total;
}

fn sumProducts(a: u128, b: u128, size: Size, dual: Dual) i128 {
    var total: i128 = 0;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        const partner = if (dual.exchange) e ^ 1 else e;
        const x: i128 = int.extend(qreg.elem(a, size, e), size, dual.unsigned);
        const y: i128 = int.extend(qreg.elem(b, size, partner), size, dual.unsigned);
        const p = x * y;
        total += if (dual.subtract and e & 1 == 1) -p else p;
    }
    return total;
}

fn wrap32(v: i128) u32 {
    return @truncate(@as(u128, @bitCast(v)));
}

fn wrap64(v: i128) u64 {
    return @truncate(@as(u128, @bitCast(v)));
}

/// VADDV{A}: the lanes of `a` summed into `acc`.
pub fn addv(acc: u32, a: u128, size: Size, unsigned: bool) u32 {
    return wrap32(@as(i128, acc) + sumLanes(a, size, unsigned));
}

/// VADDLV{A}: the 32-bit lanes of `a` summed into the pair `acc`.
pub fn addlv(acc: u64, a: u128, unsigned: bool) u64 {
    return wrap64(@as(i128, acc) + sumLanes(a, .word, unsigned));
}

/// VMLADAV{A}{X} or VMLSDAV{A}{X} into a 32-bit register.
pub fn mladav(acc: u32, a: u128, b: u128, size: Size, dual: Dual) u32 {
    return wrap32(@as(i128, acc) + sumProducts(a, b, size, dual));
}

/// VMLALDAV{A}{X} or VMLSLDAV{A}{X} into a register pair.
pub fn mlaldav(acc: u64, a: u128, b: u128, size: Size, dual: Dual) u64 {
    return wrap64(@as(i128, acc) + sumProducts(a, b, size, dual));
}
