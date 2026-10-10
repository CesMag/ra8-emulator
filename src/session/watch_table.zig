//! Every watchpoint a debugging session holds, in one table.
//!
//! `--watch` records the stores that land in one word and never stops the
//! run. A debugger wants the other thing: stop when this range is read,
//! written, or either, so the person driving it can look at who did it
//! while it is still on the stack. This table answers "does this access
//! stop the run" and knows nothing about the engine; the stop machine asks
//! it from whatever hook sees the access.
const std = @import("std");

pub const limits = struct {
    /// How many watchpoints one session may hold. The M85's DWT has four
    /// comparators; a software table is not bound by that, but a fixed size
    /// keeps it free of an allocator.
    pub const capacity: usize = 32;
};

pub const Error = error{ TableFull, NoSuchWatch, EmptyRange };

/// The handle a caller keeps to remove one entry. Never reused in a session.
pub const Id = u32;

/// Which accesses a watchpoint stops on.
pub const Kind = enum {
    read,
    write,
    access,

    /// Whether an access of kind `seen` is one this watch stops on.
    pub fn covers(self: Kind, seen: Access) bool {
        return switch (self) {
            .read => seen == .read,
            .write => seen == .write,
            .access => true,
        };
    }
};

/// What actually happened on the bus. A watch kind can cover both; an
/// access is always one or the other.
/// The DWT's access kinds, so a watch and a comparator agree on them.
pub const Access = @import("ra8_chip").periph.dwt.Access;

/// One watched range, inclusive of `first` and `last`.
pub const Watch = struct {
    first: u32,
    last: u32,
    kind: Kind,
    /// Accesses that matched, counted whether or not they stopped the run.
    seen: u32 = 0,

    /// A range of `length` bytes starting at `address`.
    pub fn span(address: u32, length: u32, kind: Kind) Error!Watch {
        if (length == 0) return Error.EmptyRange;
        return .{ .first = address, .last = address +| (length - 1), .kind = kind };
    }

    /// Whether an access of `width` bytes at `address` touches the range.
    pub fn overlaps(self: Watch, address: u32, width: u8) bool {
        const end = address +| (@max(width, 1) - 1);
        return address <= self.last and end >= self.first;
    }
};

const Slot = struct {
    id: Id,
    watch: Watch,
    enabled: bool = true,
};

/// The watch that ended a run, and the access that tripped it.
pub const Hit = struct {
    id: Id,
    address: u32,
    width: u8,
    access: Access,
};

pub const Table = struct {
    slots: [limits.capacity]Slot = undefined,
    len: usize = 0,
    next_id: Id = 1,

    /// Add a watch and hand back its id.
    pub fn add(self: *Table, watch: Watch) Error!Id {
        if (self.len == limits.capacity) return Error.TableFull;
        const id = self.next_id;
        self.next_id += 1;
        self.slots[self.len] = .{ .id = id, .watch = watch };
        self.len += 1;
        return id;
    }

    /// Take a watch out, keeping the rest in the order they were set.
    pub fn remove(self: *Table, id: Id) Error!void {
        const index = self.indexOf(id) orelse return Error.NoSuchWatch;
        var at = index;
        while (at + 1 < self.len) : (at += 1) self.slots[at] = self.slots[at + 1];
        self.len -= 1;
    }

    /// Stop matching a watch without forgetting it or its count.
    pub fn setEnabled(self: *Table, id: Id, enabled: bool) Error!void {
        const index = self.indexOf(id) orelse return Error.NoSuchWatch;
        self.slots[index].enabled = enabled;
    }

    /// The entry with this id, for a report that wants its count.
    pub fn get(self: *const Table, id: Id) ?Watch {
        const index = self.indexOf(id) orelse return null;
        return self.slots[index].watch;
    }

    /// Count the access against every enabled watch it matches and say
    /// which one, the first set, stops the run.
    pub fn hit(self: *Table, address: u32, width: u8, access: Access) ?Hit {
        var found: ?Hit = null;
        for (self.slots[0..self.len]) |*slot| {
            if (!slot.enabled) continue;
            if (!slot.watch.kind.covers(access)) continue;
            if (!slot.watch.overlaps(address, width)) continue;
            slot.watch.seen += 1;
            if (found == null) found = .{ .id = slot.id, .address = address, .width = width, .access = access };
        }
        return found;
    }

    /// Every watch in the order it was set.
    pub fn entries(self: *const Table) []const Slot {
        return self.slots[0..self.len];
    }

    fn indexOf(self: *const Table, id: Id) ?usize {
        for (self.slots[0..self.len], 0..) |slot, index| {
            if (slot.id == id) return index;
        }
        return null;
    }
};

comptime {
    std.debug.assert(limits.capacity > 0);
}
