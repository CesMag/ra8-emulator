//! The function behind the far-end device's bulk endpoints when a part is
//! plugged in there (a USB stick's mass-storage target, for one). The chip
//! owns this contract: the part (src/components/usb_stick) implements it and
//! the board plugs it in, so this block never imports a part.
pub const Function = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resetFn: *const fn (*anyopaque) void,
        commandFn: *const fn (*anyopaque, []const u8) bool,
        pendingFn: *const fn (*const anyopaque) bool,
        replyFn: *const fn (*anyopaque, []u8) usize,
    };

    /// The bus reset dropped whatever the function was answering.
    pub fn reset(self: Function) void {
        self.vtable.resetFn(self.context);
    }

    /// A bulk OUT packet. False refuses it.
    pub fn command(self: Function, packet: []const u8) bool {
        return self.vtable.commandFn(self.context, packet);
    }

    /// Whether the bulk IN endpoint has a packet owed.
    pub fn pending(self: Function) bool {
        return self.vtable.pendingFn(self.context);
    }

    /// The next bulk IN packet, at most `into.len` bytes.
    pub fn reply(self: Function, into: []u8) usize {
        return self.vtable.replyFn(self.context, into);
    }
};
