//! Conformance vectors for MVE VRINT in float_rint.zig, worked from the
//! Arm ARM (DDI0553) FPRoundInt pseudocode under StandardFPSCRValue.
const vector = @import("../../../conformance/vector.zig");
const flag = @import("../../../fpu/case.zig").flag;
const float = @import("../float.zig");
const Kind = @import("rint.zig").Kind;
const Out = @import("../vectors.zig").Out;

pub const Operands = struct {
    d: u128 = 0,
    m: u128,
    size: float.Size,
    kind: Kind,
    mask: u16 = 0xFFFF,
};

const V = vector.Vector(Operands, Out);

// F32 lanes, low first: 2.5, -2.5, 0.5, -0.5.
const halves: u128 = 0xBF000000_3F000000_C0200000_40200000;

pub const vectors = [_]V{
    .{ .encoding = "VRINTA (MVE) T1", .name = "ties away, no IXC", .input = .{ .m = halves, .size = .word, .kind = .a }, .expect = .{ .q = 0xBF800000_3F800000_C0400000_40400000 } },
    .{ .encoding = "VRINTN (MVE) T1", .name = "ties to even keeps the zero sign", .input = .{ .m = halves, .size = .word, .kind = .n }, .expect = .{ .q = 0x80000000_00000000_C0000000_40000000 } },
    .{ .encoding = "VRINTP (MVE) T1", .name = "toward plus infinity", .input = .{ .m = halves, .size = .word, .kind = .p }, .expect = .{ .q = 0x80000000_3F800000_C0000000_40400000 } },
    .{ .encoding = "VRINTM (MVE) T1", .name = "toward minus infinity", .input = .{ .m = halves, .size = .word, .kind = .m }, .expect = .{ .q = 0xBF800000_00000000_C0400000_40000000 } },
    .{ .encoding = "VRINTM (MVE) T1", .name = "F16 lanes, inactive lanes kept", .input = .{ .d = 0x7777_7777_7777_7777_7777_7777_7777_7777, .m = 0xB400_4500_BE00_3E00, .size = .half, .kind = .m, .mask = 0x00FF }, .expect = .{ .q = 0x7777_7777_7777_7777_BC00_4500_C000_3C00 } },
    .{ .encoding = "VRINTZ (MVE) T1", .name = "toward zero", .input = .{ .m = halves, .size = .word, .kind = .z }, .expect = .{ .q = 0x80000000_00000000_C0000000_40000000 } },
    .{ .encoding = "VRINTZ (MVE) T1", .name = "FZ flushes, integral and infinite kept", .input = .{ .m = 0x7F800000_501502F9_80000001_00000001, .size = .word, .kind = .z }, .expect = .{ .q = 0x7F800000_501502F9_80000000_00000000, .flags = flag.idc } },
    .{ .encoding = "VRINTX (MVE) T1", .name = "inexact raises IXC", .input = .{ .m = halves, .size = .word, .kind = .x }, .expect = .{ .q = 0x80000000_00000000_C0000000_40000000, .flags = flag.ixc } },
    .{ .encoding = "VRINTX (MVE) T1", .name = "F16 default NaN and denormals", .input = .{ .m = 0x3800_8001_0001_7BFF_3C00_FC00_7C01_3E00, .size = .half, .kind = .x }, .expect = .{ .q = 0x0000_8000_0000_7BFF_3C00_FC00_7E00_4000, .flags = flag.ioc | flag.ixc } },
};

pub const claimed = [_][]const u8{
    "VRINTA (MVE) T1", "VRINTN (MVE) T1", "VRINTP (MVE) T1",
    "VRINTM (MVE) T1", "VRINTZ (MVE) T1", "VRINTX (MVE) T1",
};

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
