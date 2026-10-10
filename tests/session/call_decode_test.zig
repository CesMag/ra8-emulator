//! Telling a call from every other Thumb instruction by its bytes.
const std = @import("std");
const ra8 = @import("ra8");
const call_decode = ra8.session.call_decode;

test "BL is a call" {
    try std.testing.expect(call_decode.isCall(&.{ 0x00, 0xF0, 0x0C, 0xF8 }));
}

test "a backwards BL is a call" {
    try std.testing.expect(call_decode.isCall(&.{ 0xFF, 0xF7, 0xFE, 0xFF }));
}

test "BLX with an immediate is a call" {
    try std.testing.expect(call_decode.isCall(&.{ 0x00, 0xF0, 0x00, 0xE8 }));
}

test "BLX with a register is a call" {
    try std.testing.expect(call_decode.isCall(&.{ 0x98, 0x47 }));
}

test "BX LR is a return, not a call" {
    try std.testing.expect(!call_decode.isCall(&.{ 0x70, 0x47 }));
}

test "a 32-bit B.W shares BL's prefix and is not a call" {
    try std.testing.expect(!call_decode.isCall(&.{ 0x00, 0xF0, 0x00, 0xB8 }));
}

test "a NOP is not a call" {
    try std.testing.expect(!call_decode.isCall(&.{ 0x00, 0xBF }));
}

test "a short read is not a call" {
    try std.testing.expect(!call_decode.isCall(&.{0x00}));
    try std.testing.expect(!call_decode.isCall(&.{ 0x00, 0xF0 }));
}
