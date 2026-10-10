const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;

const In = struct { a: u32, b: u32 };
const V = vector.Vector(In, u32);

fn add(in: In) u32 {
    return in.a +% in.b;
}

const good = [_]V{
    .{ .encoding = "ADD T1", .name = "small", .input = .{ .a = 1, .b = 2 }, .expect = 3 },
    .{ .encoding = "ADD T1", .name = "wraps", .input = .{ .a = 0xFFFF_FFFF, .b = 1 }, .expect = 0 },
};

const bad = [_]V{
    .{ .encoding = "ADD T1", .name = "holds", .input = .{ .a = 2, .b = 2 }, .expect = 4 },
    .{ .encoding = "ADD T2", .name = "wrong on purpose", .input = .{ .a = 2, .b = 2 }, .expect = 5 },
};

test "every vector holds, so there is no mismatch" {
    try std.testing.expectEqual(@as(?usize, null), vector.firstMismatch(In, u32, add, &good));
    try vector.expectAll(In, u32, add, &good);
}

test "the first wrong vector is the one reported" {
    try std.testing.expectEqual(@as(?usize, 1), vector.firstMismatch(In, u32, add, &bad));
}

test "a float result is compared by its bits, so the zero's sign counts" {
    const Neg = vector.Vector(u32, u32);
    const flip = struct {
        fn f(bits: u32) u32 {
            return bits ^ 0x8000_0000;
        }
    }.f;
    const zero = [_]Neg{.{ .encoding = "VNEG (floating-point)", .name = "+0 to -0", .input = 0, .expect = 0x8000_0000 }};
    const plus = [_]Neg{.{ .encoding = "VNEG (floating-point)", .name = "not +0", .input = 0, .expect = 0 }};
    try std.testing.expectEqual(@as(?usize, null), vector.firstMismatch(u32, u32, flip, &zero));
    try std.testing.expectEqual(@as(?usize, 0), vector.firstMismatch(u32, u32, flip, &plus));
}

test "the encodings of a vector set come back in order" {
    const names = vector.encodingsOf(In, u32, &bad);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("ADD T1", names[0]);
    try std.testing.expectEqualStrings("ADD T2", names[1]);
}
