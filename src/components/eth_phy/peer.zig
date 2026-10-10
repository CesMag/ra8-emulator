//! The far end of the wire: what the firmware has sent, and what is waiting
//! to be delivered to it. A board part (RA8EMU-1042): the DMA reaches it
//! through the wire line in src/chip/periph/eth/line.zig.
//!
//! dev's peer is a state machine that answers ARP, pings back, and runs a TCP
//! echo (board_net.c, 849 lines). None of that is here yet. What the
//! descriptor engine needs from the far end is somewhere to put a frame and
//! somewhere to take one from, so that is what this is, and the protocol peer
//! is the next slice on top of it.
//!
//! The one thing this does that dev's sink does not: it is bounded and it
//! pushes back. dev's TX sink swallows every frame, so a descriptor is
//! completed whatever happened to it.
const std = @import("std");
const desc = @import("ra8_chip").periph.eth.desc;
const line = @import("ra8_chip").periph.eth.line;

/// Frames held in one direction. Enough for a request and its reply with
/// room to spare, and it bounds what the board carries.
pub const depth: usize = 4;

pub const Frame = struct {
    bytes: [desc.limits.frame_max]u8 = undefined,
    len: u32 = 0,
};

/// A bounded queue of frames in one direction.
pub const Queue = struct {
    frames: [depth]Frame = @splat(.{}),
    head: usize = 0,
    count: usize = 0,
    /// Frames the queue had no room for. The sender still holds them.
    refused: u32 = 0,
    /// Frames that went in.
    taken: u32 = 0,

    pub fn full(self: *const Queue) bool {
        return self.count == depth;
    }

    pub fn push(self: *Queue, frame: []const u8) bool {
        if (frame.len == 0 or frame.len > desc.limits.frame_max) return false;
        if (self.full()) {
            self.refused += 1;
            return false;
        }
        const at = (self.head + self.count) % depth;
        @memcpy(self.frames[at].bytes[0..frame.len], frame);
        self.frames[at].len = @intCast(frame.len);
        self.count += 1;
        self.taken += 1;
        return true;
    }

    /// How long the frame at the front is, without taking it. The engine asks
    /// before it claims a slot, so a frame is never dequeued and dropped.
    pub fn waiting(self: *const Queue) ?u32 {
        if (self.count == 0) return null;
        return self.frames[self.head].len;
    }

    pub fn peek(self: *const Queue) ?[]const u8 {
        if (self.count == 0) return null;
        const front = &self.frames[self.head];
        return front.bytes[0..front.len];
    }

    pub fn drop(self: *Queue) void {
        if (self.count == 0) return;
        self.head = (self.head + 1) % depth;
        self.count -= 1;
    }
};

/// Both directions, named from the firmware's side of the wire.
pub const Link = struct {
    sent: Queue = .{},
    inbound: Queue = .{},

    /// The firmware's frame, on its way out. False means the far end has no
    /// room: the caller keeps the frame and the descriptor stays owned by the
    /// gateway.
    pub fn send(self: *Link, frame: []const u8) bool {
        return self.sent.push(frame);
    }

    /// A frame from the far end, waiting for a reception slot.
    pub fn offer(self: *Link, frame: []const u8) bool {
        return self.inbound.push(frame);
    }

    pub fn quiet(self: *const Link) bool {
        return self.sent.taken == 0 and self.inbound.taken == 0;
    }

    /// This link as the DMA's wire. The DMA keeps the pointer, so the link
    /// must not move afterwards.
    pub fn wire(self: *Link) line.Wire {
        return .{
            .context = self,
            .sendFn = sendOn,
            .waitingFn = waitingOn,
            .peekFn = peekOn,
            .dropFn = dropOn,
        };
    }

    fn of(context: *anyopaque) *Link {
        return @ptrCast(@alignCast(context));
    }

    fn sendOn(context: *anyopaque, frame: []const u8) bool {
        return of(context).send(frame);
    }

    fn waitingOn(context: *anyopaque) ?u32 {
        return of(context).inbound.waiting();
    }

    fn peekOn(context: *anyopaque) ?[]const u8 {
        return of(context).inbound.peek();
    }

    fn dropOn(context: *anyopaque) void {
        of(context).inbound.drop();
    }
};
