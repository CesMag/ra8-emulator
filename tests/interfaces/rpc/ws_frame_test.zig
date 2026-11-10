//! RFC 6455 Frame codec, mask XOR decoding, and binary framing tests (RA8EMU-1241).
const std = @import("std");
const ra8 = @import("ra8");
const ws_frame = ra8.rpc.ws_frame;

test "ws_frame parses 7-bit, 16-bit, and 64-bit masked client binary frames" {
    // 7-bit length (len = 5)
    var frame7 = [_]u8{ 0x82, 0x85, 0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0, 0 };
    const h7 = (try ws_frame.parseHeader(&frame7)).?;
    try std.testing.expect(h7.fin);
    try std.testing.expectEqual(ws_frame.Opcode.binary, h7.opcode);
    try std.testing.expect(h7.masked);
    try std.testing.expectEqual(@as(usize, 5), h7.payload_len);
    try std.testing.expectEqual(@as(usize, 6), h7.header_len);
    try std.testing.expectEqual(@as(usize, 11), h7.frame_len);

    // 16-bit extended length (len = 300)
    var frame16 = [_]u8{ 0x82, 0xFE, 0x01, 0x2C, 0xAA, 0xBB, 0xCC, 0xDD };
    const h16 = (try ws_frame.parseHeader(&frame16)).?;
    try std.testing.expectEqual(@as(usize, 300), h16.payload_len);
    try std.testing.expectEqual(@as(usize, 8), h16.header_len);

    // 64-bit extended length (len = 70000)
    var frame64 = [_]u8{ 0x82, 0xFF, 0, 0, 0, 0, 0, 1, 0x11, 0x70, 1, 2, 3, 4 };
    const h64 = (try ws_frame.parseHeader(&frame64)).?;
    try std.testing.expectEqual(@as(usize, 70000), h64.payload_len);
    try std.testing.expectEqual(@as(usize, 14), h64.header_len);
}

test "ws_frame unmasks payload in-place and handles mask stream offset" {
    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const mask = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };
    ws_frame.unmask(&payload, mask);
    try std.testing.expect(payload[0] == ('h' ^ 0x37));
    try std.testing.expect(payload[1] == ('e' ^ 0xFA));
    try std.testing.expect(payload[4] == ('o' ^ 0x37));
    ws_frame.unmask(&payload, mask); // double unmask restores
    try std.testing.expectEqualStrings("hello", &payload);

    // Unmask with offset
    var chunk2 = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    ws_frame.unmaskOffset(&chunk2, mask, 5); // offset 5: mask[(5+0)%4] = mask[1] = 0xFA
    try std.testing.expect(chunk2[0] == ('w' ^ 0xFA));
    ws_frame.unmaskOffset(&chunk2, mask, 5);
    try std.testing.expectEqualStrings("world", &chunk2);
}

test "ws_frame encodes unmasked server binary frames for various lengths" {
    var buf: [1024]u8 = undefined;
    const len = try ws_frame.encodeServerBinary("test payload", &buf);
    try std.testing.expectEqual(@as(usize, 2 + 12), len);
    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 12), buf[1]);
    try std.testing.expectEqualStrings("test payload", buf[2..len]);

    // Test encodeServerHeader directly for 16-bit and 64-bit boundaries
    var hdr_buf: [10]u8 = undefined;
    const h8 = ws_frame.encodeServerHeader(&hdr_buf, .binary, 8);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x08 }, h8);

    const h400 = ws_frame.encodeServerHeader(&hdr_buf, .binary, 400);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 126, 0x01, 0x90 }, h400);

    const h65536 = ws_frame.encodeServerHeader(&hdr_buf, .binary, 65536);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0 }, h65536);
}

test "ws_frame encodes and parses control frames (Close, Ping, Pong)" {
    var buf: [128]u8 = undefined;
    const pong_len = try ws_frame.encodePong("pingdata", &buf);
    try std.testing.expectEqual(@as(usize, 10), pong_len);
    try std.testing.expectEqual(@as(u8, 0x8A), buf[0]);
    try std.testing.expectEqual(@as(u8, 8), buf[1]);
    try std.testing.expectEqualStrings("pingdata", buf[2..pong_len]);

    const close_len = try ws_frame.encodeClose(ws_frame.CloseCode.normal_closure, "bye", &buf);
    try std.testing.expectEqual(@as(usize, 7), close_len);
    try std.testing.expectEqual(@as(u8, 0x88), buf[0]);
    try std.testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqualStrings("bye", buf[4..close_len]);
}

test "ws_frame error detection for reserved bits, non-minimal encoding, and invalid frames" {
    // Reserved bits set
    const rsv_frame = [_]u8{ 0xF2, 0x00 }; // RSV1 set
    try std.testing.expectError(error.ReservedBitsSet, ws_frame.parseHeader(&rsv_frame));

    // Fragmented control frame (FIN = 0, Ping opcode 0x09)
    const frag_ping = [_]u8{ 0x09, 0x00 };
    try std.testing.expectError(error.FragmentedControlFrame, ws_frame.parseHeader(&frag_ping));

    // Control frame too large (> 125)
    const big_ping = [_]u8{ 0x89, 126, 0x00, 126 };
    try std.testing.expectError(error.ControlFrameTooLarge, ws_frame.parseHeader(&big_ping));

    // Non-minimal 16-bit encoding (payload 100 encoded as 16-bit)
    const non_min16 = [_]u8{ 0x82, 126, 0x00, 100 };
    try std.testing.expectError(error.NonMinimalEncoding, ws_frame.parseHeader(&non_min16));

    // Unmasked client frame via parseClientHeader
    const unmasked = [_]u8{ 0x82, 0x05, 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.UnmaskedClientFrame, ws_frame.parseClientHeader(&unmasked));
}
