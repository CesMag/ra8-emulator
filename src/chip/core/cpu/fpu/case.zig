//! The shape of an FPU conformance vector: the operands as encoded, the FPSCR
//! controls that change the answer (rounding mode, FZ, DN), and what the
//! pseudocode produces, the result bits and the cumulative flags raised.
const fpscr_mod = @import("fpscr.zig");
const Fpscr = fpscr_mod.Fpscr;
const RMode = fpscr_mod.RMode;
const Rounding = @import("rounding.zig").Rounding;

/// One operand, as the unary forms (VSQRT, VCVT, VRINT) read it.
pub fn Unary(comptime B: type) type {
    return struct {
        a: B,
        mode: RMode = .nearest,
        fz: u1 = 0,
        dn: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .rmode = self.mode, .fz = self.fz, .dn = self.dn };
        }
    };
}

pub fn Binary(comptime B: type) type {
    return struct {
        a: B,
        b: B,
        mode: RMode = .nearest,
        fz: u1 = 0,
        dn: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .rmode = self.mode, .fz = self.fz, .dn = self.dn };
        }
    };
}

/// Three operands, as the accumulating forms read them: d is the
/// accumulator, n and m the factors.
pub const FusedOp = enum { vfma, vfms, vfnma, vfnms };

pub fn Ternary(comptime B: type) type {
    return struct {
        op: FusedOp = .vfma,
        d: B,
        n: B,
        m: B,
        mode: RMode = .nearest,
        fz: u1 = 0,
        dn: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .rmode = self.mode, .fz = self.fz, .dn = self.dn };
        }
    };
}

/// Two operands for VCMP/VCMPE: e set is the VCMPE form, which signals on
/// a quiet NaN too. The with-zero forms put 0 in b.
pub fn Compare(comptime B: type) type {
    return struct {
        a: B,
        b: B,
        e: u1 = 0,
        fz: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .fz = self.fz };
        }
    };
}

/// What a compare produces: the NZCV it writes to FPSCR, and the flags.
pub const Ordering = struct { nzcv: u4, flags: u32 = 0 };

/// One operand for the conversions between floating point and integers:
/// whether the integer side is unsigned, and the rounding mode the form
/// uses (round toward zero for VCVT to an integer, FPSCR's for VCVTR and
/// for the conversions from an integer).
pub fn Fixed(comptime B: type) type {
    return struct {
        a: B,
        unsigned: bool = false,
        mode: RMode = .nearest,
        fz: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .rmode = self.mode, .fz = self.fz };
        }
    };
}

/// One operand for VCVT between floating point and fixed point: the
/// integer side's width (16 or 32) and fraction bits, its signedness, and
/// FPSCR's rounding mode (used only on the way back to floating point).
pub fn Fraction(comptime B: type) type {
    return struct {
        a: B,
        width: u6 = 32,
        fbits: u6,
        unsigned: bool = false,
        mode: RMode = .nearest,
        fz: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .rmode = self.mode, .fz = self.fz };
        }
    };
}

/// One operand for VCVTB/VCVTT: the source register, which half of it (or
/// of the destination) the encoding names, the destination's prior value
/// (its other half survives), and the FPSCR controls that matter.
pub fn Halves(comptime B: type) type {
    return struct {
        a: B,
        top: bool = false,
        d: u32 = 0,
        ahp: u1 = 0,
        dn: u1 = 0,
        mode: RMode = .nearest,
        fz: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .ahp = self.ahp, .dn = self.dn, .rmode = self.mode, .fz = self.fz };
        }
    };
}

/// The eight-bit immediate of VMOV (immediate).
pub const Imm = struct { imm8: u8 };

/// A raw 32-bit operand, for the FPSCR moves.
pub const Word = struct { a: u32 };

/// One operand for the conversions whose encoding fixes the rounding
/// (VCVTA/N/P/M), so FPSCR supplies only FZ.
pub fn Directed(comptime B: type) type {
    return struct {
        a: B,
        unsigned: bool = false,
        rounding: Rounding,
        fz: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .fz = self.fz };
        }
    };
}

/// One operand for the VRINT forms: the rounding the form uses (FPSCR's
/// for VRINTR and VRINTX), and whether it is VRINTX, which signals IXC.
pub fn Integral(comptime B: type) type {
    return struct {
        a: B,
        rounding: Rounding = .nearest,
        exact: bool = false,
        fz: u1 = 0,
        dn: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .fz = self.fz, .dn = self.dn };
        }
    };
}

/// Two operands and the APSR flags for VSEL, with N in bit 3 of nzcv.
pub fn Select(comptime B: type) type {
    return struct {
        a: B,
        b: B,
        nzcv: u4,
        condition: @import("select/select.zig").Cond,
    };
}

pub fn Result(comptime B: type) type {
    return struct { bits: B, flags: u32 = 0 };
}

/// The cumulative flags FPSCR holds after an operation, as the low byte
/// VMRS would show.
pub fn flagsOf(fpscr: Fpscr) u32 {
    return fpscr.bits() & fpscr_mod.mask.cumulative;
}

pub const flag = struct {
    pub const ioc: u32 = 1 << 0;
    pub const dzc: u32 = 1 << 1;
    pub const ofc: u32 = 1 << 2;
    pub const ufc: u32 = 1 << 3;
    pub const ixc: u32 = 1 << 4;
    pub const idc: u32 = 1 << 7;
};
