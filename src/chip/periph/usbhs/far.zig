//! What the HS host jack talks to. The chip owns this contract: the part on
//! the far end (src/components/usb_echo, or the self-loop cable in
//! src/components/usb_loop_cable) implements it and the board plugs it in,
//! so this block never imports a part.

/// How the far end has ended the control transfer so far.
pub const Answer = enum { pending, ack, stall };

/// The calls the transfer engine makes on the far end, and nothing else.
pub const Far = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setupFn: *const fn (*anyopaque, [8]u8) void,
        statusStageFn: *const fn (*anyopaque) void,
        answerFn: *const fn (*anyopaque) Answer,
        takeInFn: *const fn (*anyopaque, []u8) ?u16,
        bulkInFn: *const fn (*anyopaque, u4, []u8) ?u16,
        bulkOutFn: *const fn (*anyopaque, u4, []const u8) bool,
        busResetFn: *const fn (*anyopaque) void,
    };

    /// A SETUP from the host.
    pub fn setup(self: Far, packet: [8]u8) void {
        self.vtable.setupFn(self.context, packet);
    }

    /// The status-stage token after a data stage.
    pub fn statusStage(self: Far) void {
        self.vtable.statusStageFn(self.context);
    }

    /// Whether the far end has acked or stalled the control transfer yet.
    pub fn answer(self: Far) Answer {
        return self.vtable.answerFn(self.context);
    }

    /// A control IN token: the packet's length, or null for a NAK.
    pub fn takeIn(self: Far, into: []u8) ?u16 {
        return self.vtable.takeInFn(self.context, into);
    }

    /// A bulk or interrupt IN token: the packet's length, or null for a NAK.
    pub fn bulkIn(self: Far, endpoint: u4, into: []u8) ?u16 {
        return self.vtable.bulkInFn(self.context, endpoint, into);
    }

    /// A bulk or interrupt OUT packet. False is a NAK.
    pub fn bulkOut(self: Far, endpoint: u4, bytes: []const u8) bool {
        return self.vtable.bulkOutFn(self.context, endpoint, bytes);
    }

    /// USBRST released on the host jack.
    pub fn busReset(self: Far) void {
        self.vtable.busResetFn(self.context);
    }
};
