//! The NVIC model (src/chip/periph/nvic/nvic.zig) as the Zig core's exception source.
//! The model reads ICSR, SHPR3, ISER/ISPR and IPR through the core's own
//! bus; taking an exception clears its pending bit and sets its active bit,
//! and a return clears the active bit again.
//!
//! SysTick and PendSV are banked: the source reads their Non-secure copy
//! through the +0x2_0000 alias as Secure, so it is there whatever state is
//! running, and remembers which copy won so taking it clears that copy
//! (RA8EMU-438).
//!
//! The NVIC is one piece of hardware whatever state the core runs in, so the
//! source reads all of it as Secure: the normal window is then the Secure
//! copy, not whichever copy the running state's own view would land on
//! (RA8EMU-465).
const bus = @import("../bus.zig");
const banked_mod = @import("../../banked.zig");
const nvic_banked = @import("../../../periph/nvic/banked.zig");
const scs_alias = @import("../../../periph/scs_alias.zig");
const nvic = @import("../../../periph/nvic/nvic.zig");
const nvic_clear = @import("../../../periph/nvic/clear.zig");
const Entry = @import("active.zig").Entry;
const Source = @import("source.zig").Source;

/// The bus in the shape the NVIC model's `core` parameter reads.
const Port = struct {
    through: bus.Bus,
    /// The running state, set to Secure while the Non-secure copy is reached.
    banked: ?*banked_mod.Banked = null,

    pub fn readWord(self: *Port, address: u32) bus.Error!u32 {
        return self.through.readWord(address);
    }

    pub fn writeWord(self: *Port, address: u32, value: u32) bus.Error!void {
        var bytes: [4]u8 = undefined;
        @import("std").mem.writeInt(u32, &bytes, value, .little);
        return self.through.write(address, &bytes);
    }

    pub fn readNonSecure(self: *Port, address: u32) bus.Error!u32 {
        const was = self.asSecure();
        defer self.restore(was);
        // A bus with nothing behind the alias has no Non-secure copy.
        return self.readWord(address + scs_alias.offset) catch |err| switch (err) {
            error.Unmapped => 0,
            else => err,
        };
    }

    pub fn writeNonSecure(self: *Port, address: u32, value: u32) bus.Error!void {
        const was = self.asSecure();
        defer self.restore(was);
        return self.writeWord(address + scs_alias.offset, value);
    }

    fn asSecure(self: *Port) ?banked_mod.State {
        const state = self.banked orelse return null;
        const was = state.current;
        state.current = .secure;
        return was;
    }

    fn restore(self: *Port, was: ?banked_mod.State) void {
        if (self.banked) |state| state.current = was orelse return;
    }
};

pub const NvicSource = struct {
    model: nvic.Nvic = .{},
    /// The core's Security state; null on a bus with no Security routing.
    banked: ?*banked_mod.Banked = null,
    /// The banked exception the last winner took from the Non-secure copy.
    last_non_secure: ?u9 = null,

    pub fn source(self: *NvicSource) Source {
        return .{ .ctx = self, .vtable = &.{ .winner = winner, .taken = taken, .returned = returned } };
    }

    fn winner(ctx: *anyopaque, through: bus.Bus) bus.Error!?Entry {
        const self: *NvicSource = @ptrCast(@alignCast(ctx));
        var port: Port = .{ .through = through, .banked = self.banked };
        const was = port.asSecure();
        defer port.restore(was);
        // Fold the write-to-clear registers first, as the model's own
        // dispatch does: on this bus they are plain memory.
        try nvic_clear.registers(&port, nvic.irq_words, nvic.clear_bits);
        try nvic_banked.fold(&port);
        const found = (try self.model.pick(&port, null)) orelse return null;
        self.last_non_secure = if (found.non_secure) @intCast(found.number) else null;
        return .{ .number = @intCast(found.number), .priority = found.priority, .non_secure = found.non_secure };
    }

    fn taken(ctx: *anyopaque, through: bus.Bus, number: u9) bus.Error!void {
        const self: *NvicSource = @ptrCast(@alignCast(ctx));
        var port: Port = .{ .through = through, .banked = self.banked };
        const was = port.asSecure();
        defer port.restore(was);
        if (self.last_non_secure == number) {
            self.last_non_secure = null;
            try nvic_banked.clear(&port, number);
        } else try nvic.clearPending(&port, number);
        try nvic.setActiveBit(&port, number, true);
    }

    fn returned(ctx: *anyopaque, through: bus.Bus, number: u9) bus.Error!void {
        const self: *NvicSource = @ptrCast(@alignCast(ctx));
        var port: Port = .{ .through = through, .banked = self.banked };
        const was = port.asSecure();
        defer port.restore(was);
        try nvic.setActiveBit(&port, number, false);
    }
};
