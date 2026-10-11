//! Every breakpoint a debugging session holds, in one table.
//!
//! `--break-sym` carried exactly one break, counted by its own hook. A
//! debugger needs as many as the person driving it sets, added and removed
//! while the run is stopped, and one place that answers "does anything stop
//! at this address". That place is this table. It knows nothing about the
//! engine: the stop machine asks it on each instruction, so it needs nothing
//! from the core.
//!
//! An entry is a `breakpoint.Break`, so the three kinds the epic asks for
//! (by address, by symbol, by symbol plus arrival count) are one kind here.
//! A symbol is resolved to its address before it reaches the table, and an
//! arrival count is the count the entry already carries.
const breakpoint = @import("../breakpoint.zig");

pub const limits = struct {
    /// How many breakpoints one session may hold at once. Hardware FPB on
    /// the M85 has eight comparators; a software table has no such limit,
    /// but a fixed size keeps the table free of an allocator and a run
    /// that needs more than this is asking a different question.
    pub const capacity: usize = 64;
};

pub const Error = error{ TableFull, NoSuchBreak, AlreadySet };

/// The handle a caller keeps to remove or report on one entry. Ids are
/// never reused within a session, so a stale id cannot name a newer break.
pub const Id = u32;

const Slot = struct {
    id: Id,
    point: breakpoint.Break,
    enabled: bool = true,
};

pub const Table = struct {
    slots: [limits.capacity]Slot = undefined,
    len: usize = 0,
    next_id: Id = 1,

    /// Add a break and hand back its id. Two breaks on one address would
    /// count every arrival twice and stop on whichever came first, which is
    /// never what was meant, so the second is refused.
    pub fn add(self: *Table, point: breakpoint.Break) Error!Id {
        if (self.find(point.address) != null) return Error.AlreadySet;
        if (self.len == limits.capacity) return Error.TableFull;
        const id = self.next_id;
        self.next_id += 1;
        self.slots[self.len] = .{ .id = id, .point = point };
        self.len += 1;
        return id;
    }

    /// Take a break out of the table. Order of the rest is kept, so a
    /// listing reads in the order the breaks were set.
    pub fn remove(self: *Table, id: Id) Error!void {
        const index = self.indexOf(id) orelse return Error.NoSuchBreak;
        var at = index;
        while (at + 1 < self.len) : (at += 1) self.slots[at] = self.slots[at + 1];
        self.len -= 1;
    }

    /// Stop counting a break without forgetting it or its count so far.
    pub fn setEnabled(self: *Table, id: Id, enabled: bool) Error!void {
        const index = self.indexOf(id) orelse return Error.NoSuchBreak;
        self.slots[index].enabled = enabled;
    }

    /// The entry with this id, for a report that wants its count.
    pub fn get(self: *const Table, id: Id) ?breakpoint.Break {
        const index = self.indexOf(id) orelse return null;
        return self.slots[index].point;
    }

    /// The id of the break set on this address, Thumb bit ignored.
    pub fn find(self: *const Table, address: u32) ?Id {
        const want = address & ~breakpoint.limits.thumb_bit;
        for (self.slots[0..self.len]) |slot| {
            if (slot.point.address & ~breakpoint.limits.thumb_bit == want) return slot.id;
        }
        return null;
    }

    /// Count an arrival at `pc` and say which break, if any, ends the run
    /// here. A disabled break neither counts nor stops. A counted break
    /// stops on its wanted arrival and on every one after it, as a break
    /// a debugger continues past has to; `--break-sym`, which stops once,
    /// keeps that rule in the frontend that offers it.
    pub fn hit(self: *Table, pc: u32) ?Id {
        const want = pc & ~breakpoint.limits.thumb_bit;
        for (self.slots[0..self.len]) |*slot| {
            if (!slot.enabled) continue;
            if (slot.point.address & ~breakpoint.limits.thumb_bit != want) continue;
            _ = slot.point.count();
            return if (slot.point.reached) slot.id else null;
        }
        return null;
    }

    /// Every break in the order it was set.
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
