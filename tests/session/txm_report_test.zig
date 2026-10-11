//! Tests for src/session/txm_report.zig: the section appears only when
//! modules are loaded, and each line names the module, state, code and data.
const std = @import("std");
const ra8 = @import("ra8");
const txm = ra8.session.txm_modules;
const report = ra8.session.txm_report;

const base: u32 = 0x2000_0000;
const head_at: u32 = base;
const first: u32 = base + 0x100;
const name_at: u32 = first + 1180;
const size = name_at - base + 16;

const Window = struct {
    bytes: []const u8,

    pub fn read(self: Window, address: u32, into: []u8) bool {
        if (address < base) return false;
        const at = address - base;
        if (at + into.len > self.bytes.len) return false;
        @memcpy(into, self.bytes[at .. at + into.len]);
        return true;
    }
};

fn put(bytes: *[size]u8, at: u32, value: u32) void {
    std.mem.writeInt(u32, bytes[at - base ..][0..4], value, .little);
}

fn oneModule() [size]u8 {
    var bytes = @as([size]u8, @splat(0));
    put(&bytes, head_at, first);
    put(&bytes, first + txm.offset.id, txm.instance_id);
    put(&bytes, first + txm.offset.name, name_at);
    put(&bytes, first + txm.offset.state, 2);
    put(&bytes, first + txm.offset.code_start, 0x6001_0000);
    put(&bytes, first + txm.offset.code_size, 2048);
    put(&bytes, first + txm.offset.data_start, 0x2004_0000);
    put(&bytes, first + txm.offset.data_size, 1024);
    put(&bytes, first + txm.offset.loaded_next, first);
    @memcpy(bytes[name_at - base ..][0..5], "hello");
    return bytes;
}

test "a loaded module prints a header and one line" {
    const bytes = oneModule();
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try report.print(&out, head_at, Window{ .bytes = &bytes });
    try std.testing.expectEqualStrings(
        "modules: 1 loaded\n  hello started code 0x60010000 size 2048 data 0x20040000 size 1024\n",
        out.buffered(),
    );
}

test "no list head symbol prints nothing" {
    const bytes = oneModule();
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try report.print(&out, null, Window{ .bytes = &bytes });
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
}

test "an empty list prints nothing" {
    var bytes = oneModule();
    put(&bytes, head_at, 0);
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try report.print(&out, head_at, Window{ .bytes = &bytes });
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
}
