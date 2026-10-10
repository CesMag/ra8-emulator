//! The shell's memory leaf (RA8EMU-821): the bound core's memory read over
//! the session link (read_memory 0x0107) into the memory pane's
//! (RA8EMU-746) Snapshot, so the pane draws in the shell unchanged. Each
//! time the registers leaf publishes that core's registers, a batch reads
//! `rows` sixteen-byte rows from the followed register (SP for the memory
//! leaf, PC for the disassembly leaf) rounded down to a row, one read per
//! row, and publishes once every row has answered. A row the session
//! refuses is drawn unreadable; a core the session has not attached keeps
//! the last values with a note. A load drops a batch in flight, since it
//! read the old image.
const proto = @import("ra8_rpc").session_rpc;
const app_codes = proto.app_codes;
const session_link = @import("session_link.zig");
const memory_pane = @import("ui/memory_pane.zig");
const pane_layout = @import("ui/pane_layout.zig");
const shell_registers = @import("shell_registers.zig");

const Env = proto.Client.Env;
const per_row = memory_pane.per_row;
pub const Snapshot = memory_pane.Snapshot;

/// Rows one batch reads: more than a leaf shows at a usual window size.
pub const rows: usize = 32;
const row_mask: u32 = ~@as(u32, per_row - 1);

pub const Memory = struct {
    core: proto.Core,
    /// A batch is due on the next attach.
    want: bool = false,
    /// The followed address for the next batch; rows start at its row.
    address: u32 = 0,
    /// The followed address of the batch in flight.
    asked_from: u32 = 0,
    /// The followed address of the published batch, `now`.
    from: u32 = 0,
    /// The registers batch this leaf last followed (Registers.serial).
    seen: u32 = 0,
    /// The ids of the batch in flight, one per row.
    asked: [rows]?u32 = @splat(null),
    /// Answers still missing from the batch in flight.
    left: usize = 0,
    /// The next row of the open batch to send; rows when all are sent.
    next: usize = rows,
    gathered: Snapshot = .{},
    batch_refused: bool = false,
    now: ?Snapshot = null,
    refused: bool = false,
    /// A load landed while a batch was in flight: it publishes nothing.
    stale: bool = false,

    /// Read next from the row holding `address`, following registers batch
    /// `serial`.
    pub fn follow(self: *Memory, address: u32, serial: u32) void {
        self.seen = serial;
        self.address = address;
        self.want = true;
    }

    /// Send the due batch, one read per row, unless one is already in
    /// flight or the session has not greeted.
    pub fn attach(self: *Memory, link: *session_link.Link) void {
        if (link.state != .connected) return;
        if (self.want and self.left == 0 and self.next == rows) self.start();
        if (self.next == rows) return;
        while (self.next < rows) : (self.next += 1) {
            const args: proto.ReadMemory = .{ .core = self.core, .address = self.gathered.rowAddress(self.next), .length = per_row };
            const asked = link.send(proto.ReadMemory, .read_memory, args) catch |err| switch (err) {
                error.TableFull => return,
                else => null,
            };
            self.asked[self.next] = asked;
            if (asked == null) self.batch_refused = true else self.left += 1;
        }
        if (self.left == 0) self.finish();
    }

    fn start(self: *Memory) void {
        self.want = false;
        self.batch_refused = false;
        self.gathered = .{ .base = self.address & row_mask, .count = rows };
        self.asked_from = self.address;
        self.next = 0;
    }

    /// An answer to the batch in flight fills its row; everything else is
    /// ignored.
    pub fn observe(self: *Memory, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => {},
            .response => |response| self.answered(response.id, response.result),
        }
    }

    /// A new image: wait for its registers and drop what came before.
    pub fn reload(self: *Memory) void {
        self.want = false;
        self.now = null;
        self.next = rows;
        self.stale = self.left != 0;
    }

    /// The leaf's note while it has no values to draw, or null.
    pub fn note(self: *const Memory) ?[]const u8 {
        if (self.refused) return "the session would not read memory";
        if (self.now == null) return "waiting for memory";
        return null;
    }

    fn answered(self: *Memory, id: u32, result: Env.Result) void {
        const row = self.slot(id) orelse return;
        self.asked[row] = null;
        self.left -= 1;
        switch (result) {
            .ok => |body| self.fill(row, body),
            .err => |code| if (@backingInt(code) == app_codes.no_core) {
                self.batch_refused = true;
            },
        }
        if (self.left == 0 and self.next == rows) self.finish();
    }

    /// A whole row read becomes readable; a short or garbled one stays
    /// unreadable, as a refused one does.
    fn fill(self: *Memory, row: usize, body: []const u8) void {
        const read = proto.decode(proto.Memory, body) catch return;
        if (read.bytes.len != per_row) return;
        @memcpy(self.gathered.bytes[row * per_row ..][0..per_row], read.bytes);
        @memset(self.gathered.readable[row * per_row ..][0..per_row], true);
    }

    fn slot(self: *const Memory, id: u32) ?usize {
        if (self.left == 0) return null;
        for (self.asked, 0..) |asked, row| if (asked == id) return row;
        return null;
    }

    /// A whole batch publishes; one the session refused keeps the last
    /// snapshot, and one sent before a load is dropped.
    fn finish(self: *Memory) void {
        if (self.stale) {
            self.stale = false;
            return;
        }
        self.refused = self.batch_refused;
        if (self.refused) return;
        self.now = self.gathered;
        self.from = self.asked_from;
    }
};

/// One model per core, so each leaf shows the core it is bound to.
pub const Pair = struct {
    cores: [2]Memory = .{ .{ .core = .cpu0 }, .{ .core = .cpu1 } },
    /// The register each core's batch starts from.
    follows: shell_registers.Register = .sp,

    pub fn of(self: *const Pair, core: pane_layout.Core) *const Memory {
        return &self.cores[@backingInt(core)];
    }

    /// Follow each core's registers once they publish a batch this leaf
    /// has not followed yet.
    pub fn follow(self: *Pair, registers: *const shell_registers.Pair) void {
        for (&self.cores, registers.cores) |*model, core| {
            if (core.serial == model.seen) continue;
            const address = core.value(self.follows) orelse continue;
            model.follow(address, core.serial);
        }
    }

    pub fn attach(self: *Pair, link: *session_link.Link) void {
        for (&self.cores) |*model| model.attach(link);
    }

    pub fn observe(self: *Pair, arrival: session_link.Arrival) void {
        for (&self.cores) |*model| model.observe(arrival);
    }

    pub fn reload(self: *Pair) void {
        for (&self.cores) |*model| model.reload();
    }
};
