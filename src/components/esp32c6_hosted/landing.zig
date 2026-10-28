//! The bridge's two dealings with the application's record of host frames
//! (hold.zig `Landing`): telling it the frames a call put on the queue, and,
//! while traffic is held, landing the frames it has recorded for the call.
const frame = @import("frame.zig");
const Queue = @import("queue.zig").Queue;
const hold = @import("hold.zig");

/// A call of `site` began. Counts it for the record. Returns whether host
/// traffic is held; held, the recorded frames due for the call land on
/// `queue` instead of a host socket being touched.
pub fn enter(landing: ?hold.Landing, held_by: ?hold.Hold, queue: *Queue, site: hold.Site) bool {
    if (landing) |l| l.enterFn(l.context, site);
    const by = held_by orelse return false;
    if (!by.heldFn(by.context)) return false;
    const l = landing orelse return true;
    var bytes: [frame.max_payload]u8 = undefined;
    while (l.dueFn(l.context, site, &bytes)) |due| {
        if (!push(queue, bytes[0..due.len])) {
            l.failFn(l.context);
            break;
        }
    }
    return true;
}

/// Tells the record about the frames a call put on `queue` after its first
/// `before`, in order.
/// Returns the queue's length, the next call's `before`.
pub fn report(landing: ?hold.Landing, queue: *Queue, before: usize, site: hold.Site, kind: hold.Kind) usize {
    const l = landing orelse return queue.len;
    var index = before;
    while (index < queue.len) : (index += 1) {
        const parsed = frame.parse(&queue.slots[(queue.head + index) % queue.slots.len]) catch continue;
        l.landedFn(l.context, site, kind, parsed.payload);
    }
    return queue.len;
}

fn push(queue: *Queue, ethernet: []const u8) bool {
    var hosted: [frame.frame_size]u8 = undefined;
    frame.build(&hosted, .{ .interface = .sta, .if_num = 0 }, ethernet) catch return false;
    return queue.push(&hosted);
}
