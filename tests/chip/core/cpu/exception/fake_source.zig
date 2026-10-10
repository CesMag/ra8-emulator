//! An exception source a test sets by hand: one pending exception or none,
//! and a record of what the core took and returned from.
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const exception = ra8.chip.core.cpu.exception;
const Entry = exception.active.Entry;

pub const Fake = struct {
    pending: ?Entry = null,
    taken: u32 = 0,
    returned: u32 = 0,
    last_returned: ?u9 = null,

    pub fn source(self: *Fake) exception.source.Source {
        return .{ .ctx = self, .vtable = &.{ .winner = winner, .taken = take, .returned = ret } };
    }

    fn winner(ctx: *anyopaque, _: bus.Bus) bus.Error!?Entry {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.pending;
    }

    fn take(ctx: *anyopaque, _: bus.Bus, number: u9) bus.Error!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.taken += 1;
        if (self.pending) |p| {
            if (p.number == number) self.pending = null;
        }
    }

    fn ret(ctx: *anyopaque, _: bus.Bus, number: u9) bus.Error!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.returned += 1;
        self.last_returned = number;
    }
};
