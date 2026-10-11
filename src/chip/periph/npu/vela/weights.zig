//! The Ethos-U55 weight stream: the compressed weights a convolution reads,
//! decoded back to the signed 9-bit values Vela packed.
//!
//! WHAT: a port of the decoder in Vela 3.12.0's mlw_codec (mlw_decode.c).
//! A stream is a run of slices. Each slice has a header, an optional
//! palette, then chunks of Golomb-Rice coded weight indices interleaved with
//! zero-run lengths. A 0b111 slice header pads to the next byte.
//! WHY: the U55 TRM does not spell the format out; Vela's codec is the
//! reference both the compiler and the hardware agree on.
const std = @import("std");

pub const Error = error{ Underrun, BadHeader, TooLarge, OutOfMemory };

const zdiv_disable = 6;
const zdiv_eos = 7;
const wdiv_uncompressed = 7;
const max_symbols = 12;
/// The widest weight index the hardware takes: 9 bits.
const index_limit = 512;

/// Decode a whole weight stream. The caller owns the returned slice.
pub fn decode(gpa: std.mem.Allocator, stream: []const u8) Error![]i16 {
    var d = Decoder{ .gpa = gpa, .bits = .{ .buf = stream }, .out = .empty };
    errdefer d.out.deinit(gpa);
    while (try d.nextSlice()) {}
    return d.out.toOwnedSlice(gpa);
}

/// The stream read least-significant bit first.
const Bits = struct {
    buf: []const u8,
    pos: usize = 0,

    fn get(self: *Bits, len: u5) Error!u32 {
        var data: u32 = 0;
        var i: u5 = 0;
        while (i < len) : (i += 1) {
            const byte = self.pos >> 3;
            if (byte >= self.buf.len) return error.Underrun;
            const bit = (self.buf[byte] >> @intCast(self.pos & 7)) & 1;
            data |= @as(u32, bit) << i;
            self.pos += 1;
        }
        return data;
    }

    fn alignByte(self: *Bits) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }

    fn atEnd(self: *const Bits) bool {
        return self.pos / 8 == self.buf.len;
    }
};

/// Indices below `size` look a value up; the rest are offset directly.
/// Values are sign-magnitude with the sign in bit 0.
const Palette = struct {
    entries: [32]u16 = @splat(0),
    size: u32 = 0,
    bits: u5 = 2,
    direct_offset: u32 = 0,

    fn weight(self: *const Palette, index: u32) Error!i16 {
        if (index >= index_limit) return error.TooLarge;
        const val: u32 = if (index < self.size)
            self.entries[index]
        else
            index - self.size + self.direct_offset;
        const mag: i16 = @intCast(val >> 1);
        return if (val & 1 == 1) -mag else mag;
    }

    fn uncompressedBits(self: *const Palette) u5 {
        if (self.size == 0) return self.bits;
        var b: u5 = 0;
        while ((@as(u32, 1) << b) < self.size) b += 1;
        return b;
    }
};

const Header = struct {
    zdiv: u32,
    nvalues: u32,
    wdiv: u5,
    trunc: bool,
    new_palette: bool,
    uncompressed: bool,

    fn zeroRun(self: Header) bool {
        return self.zdiv != zdiv_disable;
    }
};

/// One of the two interleaved symbol streams: weights or zero runs.
/// Each chunk reads this chunk's unary parts and the last chunk's
/// remainders, so the previous chunk's quotients are kept.
const Side = struct {
    pos: u32 = 0,
    prev_pos: u32 = 0,
    q: [max_symbols]u32 = @splat(0),
    nsymbols: u32 = 0,
    carry: u32 = 0,
    enable: bool = false,
    prev_q: [max_symbols]u32 = @splat(0),
    prev_nsymbols: u32 = 0,
    prev_enable: bool = false,

    fn zeroUnary(self: *Side, bits: *Bits, len: u5) Error!void {
        const unary = try bits.get(len);
        var cnt = self.carry;
        self.nsymbols = 0;
        var i: u5 = 0;
        while (i < len) : (i += 1) {
            if ((unary >> i) & 1 == 1) {
                cnt += 1;
            } else {
                self.push(cnt);
                cnt = 0;
            }
        }
        self.carry = cnt;
        self.pos += self.nsymbols;
    }

    fn weightUnary(self: *Side, bits: *Bits, unary0: u32, max: u5, trunc: bool) Error!void {
        const mask = (@as(u32, 1) << max) - 1;
        var unary1 = try bits.get(@intCast(@popCount(unary0 & mask)));
        var cnt = self.carry;
        self.nsymbols = 0;
        var i: u5 = 0;
        while (i < max) : (i += 1) {
            var code: u32 = 0;
            if ((unary0 >> i) & 1 == 1) {
                code += 1;
                if (unary1 & 1 == 1) code += 1;
                unary1 >>= 1;
            }
            cnt += code;
            if (code < 2 or trunc) {
                self.push(cnt);
                cnt = 0;
            }
        }
        self.carry = cnt;
        self.pos += self.nsymbols;
    }

    fn push(self: *Side, quotient: u32) void {
        self.q[self.nsymbols] = quotient;
        self.nsymbols += 1;
    }

    fn remainders(self: *Side, bits: *Bits, div: u5, values: []u32) Error!void {
        var i: u32 = 0;
        while (i < self.prev_nsymbols and self.prev_pos < values.len) : (i += 1) {
            const remain = try bits.get(div);
            const high = std.math.shlExact(u32, self.prev_q[i], div) catch return error.TooLarge;
            values[self.prev_pos] = std.math.add(u32, high, remain) catch return error.TooLarge;
            self.prev_pos += 1;
        }
    }

    fn shift(self: *Side) void {
        self.prev_enable = self.enable;
        self.prev_nsymbols = self.nsymbols;
        self.prev_q = self.q;
    }
};

const Decoder = struct {
    gpa: std.mem.Allocator,
    bits: Bits,
    out: std.ArrayList(i16),
    palette: Palette = .{},
    first: bool = true,
    prev_zdiv: u32 = 0,

    fn nextSlice(self: *Decoder) Error!bool {
        var zdiv = try self.bits.get(3);
        while (zdiv == zdiv_eos) {
            self.bits.alignByte();
            self.first = true;
            if (self.bits.atEnd()) break;
            zdiv = try self.bits.get(3);
        }
        if (self.bits.atEnd()) return false;
        const header = try self.readHeader(zdiv);
        try self.decodeSlice(header);
        return true;
    }

    fn readHeader(self: *Decoder, zdiv: u32) Error!Header {
        if (zdiv >= 4 and zdiv != zdiv_disable) return error.BadHeader;
        const nvalues = try self.bits.get(15) + 1;
        const wdiv = try self.bits.get(3);
        const trunc = try self.bits.get(1) == 1;
        const new_palette = try self.bits.get(1) == 1;
        if (self.first and !new_palette) return error.BadHeader;
        self.first = false;
        const same_mode = (zdiv == zdiv_disable) == (self.prev_zdiv == zdiv_disable);
        if (!new_palette and !same_mode) return error.BadHeader;
        self.prev_zdiv = zdiv;
        if (new_palette) try self.readPalette();
        const uncompressed = wdiv == wdiv_uncompressed;
        if (!uncompressed and wdiv >= 6) return error.BadHeader;
        return .{
            .zdiv = zdiv,
            .nvalues = nvalues,
            .wdiv = if (uncompressed) self.palette.uncompressedBits() else @intCast(wdiv),
            .trunc = trunc,
            .new_palette = new_palette,
            .uncompressed = uncompressed,
        };
    }

    fn readPalette(self: *Decoder) Error!void {
        const p = &self.palette;
        p.direct_offset = try self.bits.get(5);
        const size = try self.bits.get(5);
        p.size = if (size > 0) size + 1 else 0;
        p.bits = @intCast(try self.bits.get(3) + 2);
        for (p.entries[0..p.size]) |*entry| entry.* = @intCast(try self.bits.get(p.bits));
    }

    fn decodeSlice(self: *Decoder, h: Header) Error!void {
        const gpa = self.gpa;
        const w_values = try gpa.alloc(u32, h.nvalues);
        defer gpa.free(w_values);
        const z_values = try gpa.alloc(u32, h.nvalues + @intFromBool(h.new_palette));
        defer gpa.free(z_values);
        @memset(w_values, 0);
        @memset(z_values, 0);
        try self.runChunks(h, w_values, z_values);
        try self.interleave(h, w_values, z_values);
    }

    fn runChunks(self: *Decoder, h: Header, w_values: []u32, z_values: []u32) Error!void {
        var w = Side{};
        var z = Side{};
        const zero_run = h.zeroRun();
        const z_len: u5 = if (h.zdiv < 3) 12 else 8;
        const z_div: u5 = if (zero_run) @intCast(h.zdiv) else 0;
        const w_max: u5 = if (h.uncompressed and h.wdiv > 5) 8 else 12;
        while (true) {
            const balance: i64 = if (zero_run) @as(i64, w.pos) - @as(i64, z.pos) else 0;
            w.enable = (balance < 8 or !zero_run) and w.pos < w_values.len;
            z.enable = balance >= 0 and zero_run and z.pos < z_values.len;
            const unary0: u32 = if (w.enable and !h.uncompressed) try self.bits.get(12) else 0;
            if (z.enable) try z.zeroUnary(&self.bits, z_len);
            if (w.enable) try w.weightUnary(&self.bits, unary0, w_max, h.trunc);
            if (w.prev_enable) try w.remainders(&self.bits, h.wdiv, w_values);
            if (z.prev_enable) try z.remainders(&self.bits, z_div, z_values);
            w.shift();
            z.shift();
            if (!w.prev_enable and !z.prev_enable) return;
        }
    }

    fn interleave(self: *Decoder, h: Header, w_values: []const u32, z_values: []const u32) Error!void {
        const zero_run = h.zeroRun();
        const lead = @intFromBool(h.new_palette);
        if (h.new_palette and zero_run) try self.out.appendNTimes(self.gpa, 0, z_values[0]);
        for (w_values, 0..) |index, i| {
            try self.out.append(self.gpa, try self.palette.weight(index));
            if (zero_run) try self.out.appendNTimes(self.gpa, 0, z_values[i + lead]);
        }
    }
};
