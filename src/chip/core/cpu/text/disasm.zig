//! The Zig core's own disassembler (RA8EMU-17): decode with the core table,
//! then dispatch to the matching instruction-group printer.
const decode = @import("../decode/decode.zig");
const Instr = @import("../instr.zig").Instr;
const table = @import("table.zig");
const vpst = @import("mve/vpst.zig");
const Text = @import("text.zig").Text;

/// The text of instr, or null when it has no printer.
pub fn one(instr: Instr) ?Text {
    const hit = decode.decode(instr) orelse return null;
    const entry = table.findEntry(hit.group) orelse return null;
    var out: Text = .{};
    entry.print(instr, &out);
    return out;
}

/// A sequential disassembly context for instruction sets whose spelling uses
/// state established by an earlier instruction, including MVE VPT blocks.
pub const Stream = struct {
    pattern: vpst.Pattern = .{ .name = "", .suffixes = .{ 0, 0, 0, 0 }, .len = 0 },
    next: usize = 0,

    pub fn format(self: *Stream, instr: Instr) ?Text {
        const hit = decode.decode(instr) orelse {
            self.clear();
            return null;
        };
        const entry = table.findEntry(hit.group) orelse {
            self.consume();
            return null;
        };
        var out: Text = .{};
        if (std.mem.eql(u8, hit.group, "mve_vpst")) {
            self.pattern = vpst.pattern(instr);
            self.next = 0;
            entry.print(instr, &out);
            return out;
        }
        if (std.mem.eql(u8, hit.group, "mve_vcmp") or std.mem.eql(u8, hit.group, "mve_vcmp_fp")) {
            const mask: u4 = if (std.mem.eql(u8, hit.group, "mve_vcmp"))
                @import("../ops/mve/vcmp/vcmp.zig").fields(instr).?.mask
            else
                @import("../ops/mve/vcmp/fp.zig").fields(instr).?.mask;
            if (mask != 0) {
                self.pattern = vpst.pattern(instr);
                self.next = 0;
            }
            entry.print(instr, &out);
            return out;
        }
        if (self.next < @as(usize, self.pattern.len)) {
            const suffix = self.pattern.suffixes[self.next .. self.next + 1];
            if (entry.predicated) |print| {
                print(instr, &out, suffix);
            } else {
                entry.print(instr, &out);
            }
            self.consume();
            return out;
        }
        entry.print(instr, &out);
        return out;
    }

    fn consume(self: *Stream) void {
        if (self.next < @as(usize, self.pattern.len)) self.next += 1;
        if (self.next == @as(usize, self.pattern.len)) self.clear();
    }

    fn clear(self: *Stream) void {
        self.pattern = .{ .name = "", .suffixes = .{ 0, 0, 0, 0 }, .len = 0 };
        self.next = 0;
    }
};

const std = @import("std");
