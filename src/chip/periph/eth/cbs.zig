//! ETHA's credit-based shaper configuration and monitoring registers.
//!
//! Configuration-change writes copy admin enable, increment, and upper-limit
//! values into their operational mirrors. Credit evolution is not modeled.
const lanes = @import("../lanes.zig");
const periph = @import("../registry.zig");

pub const off = struct {
    pub const admin_enable: u32 = 0x0200;
    pub const config_change: u32 = 0x0204;
    pub const increment: u32 = 0x0220;
    pub const upper_limit: u32 = 0x0240;
    pub const oper_enable: u32 = 0x0260;
    pub const oper_increment: u32 = 0x0280;
    pub const oper_upper_limit: u32 = 0x02a0;
    pub const gate_state: u32 = 0x02c0;
    pub const class_count: usize = 8;
    pub const word_bytes: u32 = 4;
    pub const span: u32 = gate_state + word_bytes - admin_enable;
    pub const increment_mask: u32 = 0x000f_ffff;
    pub const upper_limit_mask: u32 = 0x7fff_ffff;
};

pub const Cbs = struct {
    base: u32,
    admin_enabled: u32 = 0,
    enabled: u32 = 0,
    admin_increment: [off.class_count]u32 = @splat(0),
    admin_upper_limit: [off.class_count]u32 = @splat(off.upper_limit_mask),
    increment: [off.class_count]u32 = @splat(0),
    upper_limit: [off.class_count]u32 = @splat(off.upper_limit_mask),
    writes: u32 = 0,

    pub fn init(base: u32) Cbs {
        return .{ .base = base };
    }

    pub fn read(self: *Cbs, address: u32, width: u3) u32 {
        const relative = address -% self.base;
        const offset = lanes.word(relative);
        const whole = switch (offset) {
            off.admin_enable => self.admin_enabled,
            off.config_change => 0,
            off.oper_enable => self.enabled,
            off.gate_state => 0,
            else => self.classWord(offset) orelse 0,
        };
        return lanes.part(whole, lanes.lane(relative), width);
    }

    pub fn write(self: *Cbs, address: u32, width: u3, value: u32) void {
        self.writes +%= 1;
        const relative = address -% self.base;
        const offset = lanes.word(relative);
        const asked = lanes.merge(self.word(offset), lanes.lane(relative), width, value);
        switch (offset) {
            off.admin_enable => self.admin_enabled = asked & 0xff,
            off.config_change => self.apply(asked & 0xff),
            else => self.setAdminClass(offset, asked),
        }
    }

    pub fn quiet(self: *const Cbs) bool {
        return self.writes == 0;
    }

    pub fn block(self: *Cbs) periph.Block {
        return .{
            .name = "ETHA-CBS",
            .base = self.base + off.admin_enable,
            .size = off.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    fn apply(self: *Cbs, changed: u32) void {
        for (0..off.class_count) |index| {
            const bit: u32 = @as(u32, 1) << @intCast(index);
            if (changed & bit == 0) continue;
            self.enabled = (self.enabled & ~bit) | (self.admin_enabled & bit);
            self.increment[index] = self.admin_increment[index];
            self.upper_limit[index] = self.admin_upper_limit[index];
        }
    }

    fn word(self: *const Cbs, offset: u32) u32 {
        return switch (offset) {
            off.admin_enable => self.admin_enabled,
            off.config_change => 0,
            off.oper_enable => self.enabled,
            off.gate_state => 0,
            else => self.classWord(offset) orelse 0,
        };
    }

    fn classWord(self: *const Cbs, offset: u32) ?u32 {
        if (slot(offset, off.increment)) |index| return self.admin_increment[index];
        if (slot(offset, off.upper_limit)) |index| return self.admin_upper_limit[index];
        if (slot(offset, off.oper_increment)) |index| return self.increment[index];
        if (slot(offset, off.oper_upper_limit)) |index| return self.upper_limit[index];
        return null;
    }

    fn setAdminClass(self: *Cbs, offset: u32, value: u32) void {
        if (slot(offset, off.increment)) |index| {
            self.admin_increment[index] = value & off.increment_mask;
            return;
        }
        if (slot(offset, off.upper_limit)) |index| {
            self.admin_upper_limit[index] = value & off.upper_limit_mask;
        }
    }
};

fn slot(offset: u32, first: u32) ?usize {
    if (offset < first or offset >= first + off.word_bytes * off.class_count) return null;
    return (offset - first) / off.word_bytes;
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Cbs = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Cbs = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
