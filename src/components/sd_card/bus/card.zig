//! The SD card on the other side of the host controller: what it holds, and
//! which state it is in when a command arrives.
//!
//! The controller reaches it only through periph/sdhi/line.zig (adapter
//! in bus_line.zig). Split out of sdhi.zig because the two answer different questions. The
//! controller owns a register window, a FIFO and a set of status flags; the
//! card owns 512-byte blocks, a relative address, and the five-state walk
//! the SD Physical Layer puts it through before a block command means
//! anything: idle -> ready -> ident -> stby -> tran.
//!
//! The blocks themselves are the one card model both fronts share,
//! image.zig (RA8EMU-1053): the SPI-mode front in card.zig and this SD-bus
//! front each hold an `image.Image` and keep only their own protocol state.
//! `--sd-image PATH` loads a raw host image into it (RA8EMU-568), so the
//! store is the copy-on-write overlay: firmware writes land here and the
//! file is only rewritten by the application (host disk_file.replace),
//! which `--sd-writable` asks for. With no image the capacity is the
//! model's own choice, stated below.
const std = @import("std");
const image = @import("../image.zig");
const sd_line = @import("ra8_chip").periph.sdhi.line;

pub const geometry = struct {
    /// The SD block size every command here works in.
    pub const block_bytes = sd_line.block_bytes;
    /// CSD v2 counts capacity in units of 1024 blocks.
    pub const csize_unit: u32 = 1024;
    /// The model's own capacity, 32 MiB, picked so C_SIZE is exact and a
    /// filesystem image has somewhere to go. Nothing in the tree fixes it.
    pub const capacity_blocks: u32 = 64 * 1024;
};

/// What a card answers with: the SD bus words the controller declares.
pub const response = sd_line.response;

/// The SD card state machine, as far as the identification sequence and a
/// block transfer need it.
pub const State = enum {
    idle,
    ready,
    ident,
    stby,
    tran,
};

const Block = image.Block;

pub const LoadError = image.LoadError;

pub const Card = struct {
    /// The card's blocks and size, shared with the SPI-mode front.
    img: image.Image,
    state: State = .idle,
    /// Blocks written that were past the end of the card.
    past_end: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Card {
        var img = image.Image.init(allocator);
        img.capacity_blocks = geometry.capacity_blocks;
        return .{ .img = img };
    }

    pub fn deinit(self: *Card) void {
        self.img.deinit();
    }

    /// Free every held block and put the card back in idle, which is where
    /// a power cycle leaves it.
    pub fn release(self: *Card) void {
        self.img.release();
        self.state = .idle;
        self.past_end = 0;
    }

    /// Blocks currently holding data. A run that only read the card holds
    /// none.
    pub fn held(self: *const Card) u32 {
        return @intCast(self.img.held());
    }

    /// How big the card is: the model's default, or the loaded image's size.
    pub fn capacity(self: *const Card) u32 {
        return self.img.capacity_blocks;
    }

    pub fn holds(self: *const Card, lba: u32) bool {
        return self.img.inRange(lba);
    }

    /// Back the card with a raw image: whole C_SIZE units, so the CSD can
    /// state it exactly. Zero blocks stay sparse. Refused on a card that
    /// already holds data.
    pub fn loadBytes(self: *Card, bytes: []const u8) LoadError!void {
        self.img.loadBytes(bytes) catch |err| {
            if (err == error.OutOfMemory) self.img.capacity_blocks = geometry.capacity_blocks;
            return err;
        };
    }

    /// Every block of the card in order, for the host to write back.
    pub fn writeTo(self: *const Card, out: *std.Io.Writer) !void {
        try self.img.writeTo(out);
    }

    /// A block command is only legal from the transfer state, which is
    /// where CMD7 leaves a selected card.
    pub fn canTransfer(self: *const Card) bool {
        return self.state == .tran;
    }

    /// One block out of the card. A block nobody wrote reads as zeros.
    pub fn read(self: *Card, lba: u32, out: *Block) bool {
        @memset(out, 0);
        if (self.img.read(lba, out)) return true;
        self.past_end += 1;
        return false;
    }

    /// One block into the card, held from here on.
    pub fn write(self: *Card, lba: u32, data: *const Block) bool {
        if (!self.holds(lba)) {
            self.past_end += 1;
            return false;
        }
        return self.img.write(lba, data);
    }

    /// CMD0: back to idle from wherever the card was.
    pub fn goIdle(self: *Card) void {
        self.state = .idle;
    }

    /// ACMD41 with the busy bit answered: the card has finished powering up.
    pub fn powerUp(self: *Card) void {
        if (self.state == .idle) self.state = .ready;
    }

    /// CMD2: the card publishes its CID and moves to identification.
    pub fn publishCid(self: *Card) bool {
        if (self.state != .ready) return false;
        self.state = .ident;
        return true;
    }

    /// CMD3: the card takes a relative address and stands by.
    pub fn takeAddress(self: *Card) bool {
        if (self.state != .ident) return false;
        self.state = .stby;
        return true;
    }

    /// CMD7 with this card's RCA selects it; with any other address it
    /// deselects, which is how a multi-card bus works.
    pub fn select(self: *Card, rca: u16) void {
        const mine: u16 = @intCast(response.rca_value >> 16);
        self.state = if (rca == mine) .tran else .stby;
    }

    /// The CSD v2 response words for this card's capacity, low word first.
    pub fn csd(self: *const Card) [4]u32 {
        const size = @max(self.capacity(), geometry.csize_unit);
        const c_size = (size / geometry.csize_unit) - 1;
        return .{
            0,
            (c_size & 0xFFFF) << 16,
            (c_size >> 16) & 0x3F,
            response.csd_v2,
        };
    }
};
