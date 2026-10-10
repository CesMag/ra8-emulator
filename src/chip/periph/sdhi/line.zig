//! The card slot as SDHI0 sees it (ADR 0004): the words an SD card answers
//! with, which the controller drops into SD_RSP10..76, and the card itself
//! behind a line the board plugs in. The card is a part outside the MCU
//! (src/components/sd_card/bus_card.zig); the controller only talks to this.
//!
//! With nothing plugged in the slot is `absent`: it holds nothing, never
//! reaches the transfer state, refuses CMD2, CMD3 and every block, and its
//! CSD reads as zero, which is what a driver sees from an empty slot.

/// The SD block size every command here works in.
pub const block_bytes: u32 = 512;
pub const Block = [block_bytes]u8;

/// What a card answers with. The controller drops these into SD_RSP10..76.
pub const response = struct {
    /// R1: TRAN state, ready for data.
    pub const r1_ready: u32 = 0x0000_0900;
    /// R1 bit 5, APP_CMD accepted, so the ACMD that follows is honoured.
    pub const r1_app_cmd: u32 = 0x0000_0020;
    /// R1 bit 22, ILLEGAL_COMMAND: the card understood the command and
    /// refused it in this state.
    pub const r1_illegal: u32 = 0x0040_0000;
    /// R7 for CMD8: 2.7-3.6V plus the 0xAA check pattern echoed back.
    pub const r7_if_cond: u32 = 0x0000_01AA;
    /// R3 for ACMD41: power-up done, CCS set (SDHC/SDXC), voltage window.
    pub const ocr_ready: u32 = 0xC0FF_8000;
    /// The CID fill dev uses, "RA8D" packed, kept so a log reads the same.
    pub const cid_word: u32 = 0x5241_3844;
    /// CMD3 hands out RCA 1 in the top half of R6.
    pub const rca_value: u32 = 0x0001_0000;
    /// CSD structure version 2 in the top word.
    pub const csd_v2: u32 = 0x4000_0000;
};

pub const Line = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        heldFn: *const fn (context: *const anyopaque) u32,
        canTransferFn: *const fn (context: *const anyopaque) bool,
        readFn: *const fn (context: *anyopaque, lba: u32, out: *Block) bool,
        writeFn: *const fn (context: *anyopaque, lba: u32, data: *const Block) bool,
        goIdleFn: *const fn (context: *anyopaque) void,
        powerUpFn: *const fn (context: *anyopaque) void,
        publishCidFn: *const fn (context: *anyopaque) bool,
        takeAddressFn: *const fn (context: *anyopaque) bool,
        selectFn: *const fn (context: *anyopaque, rca: u16) void,
        csdFn: *const fn (context: *const anyopaque) [4]u32,
    };

    /// Blocks the card holds data for.
    pub fn held(self: Line) u32 {
        return self.vtable.heldFn(self.context);
    }

    /// A block command is only legal from the transfer state.
    pub fn canTransfer(self: Line) bool {
        return self.vtable.canTransferFn(self.context);
    }

    /// One block out of the card; false when the card refused it.
    pub fn read(self: Line, lba: u32, out: *Block) bool {
        return self.vtable.readFn(self.context, lba, out);
    }

    /// One block into the card; false when the card refused it.
    pub fn write(self: Line, lba: u32, data: *const Block) bool {
        return self.vtable.writeFn(self.context, lba, data);
    }

    /// CMD0.
    pub fn goIdle(self: Line) void {
        self.vtable.goIdleFn(self.context);
    }

    /// ACMD41 answered with the busy bit.
    pub fn powerUp(self: Line) void {
        self.vtable.powerUpFn(self.context);
    }

    /// CMD2; false when the card is not ready for it.
    pub fn publishCid(self: Line) bool {
        return self.vtable.publishCidFn(self.context);
    }

    /// CMD3; false when the card is not identifying.
    pub fn takeAddress(self: Line) bool {
        return self.vtable.takeAddressFn(self.context);
    }

    /// CMD7 with the RCA in the top half of the argument.
    pub fn select(self: Line, rca: u16) void {
        self.vtable.selectFn(self.context, rca);
    }

    /// The CSD response words, low word first.
    pub fn csd(self: Line) [4]u32 {
        return self.vtable.csdFn(self.context);
    }
};

var empty_slot: u8 = 0;

/// An empty slot.
pub const absent: Line = .{ .context = &empty_slot, .vtable = &absent_vtable };

const absent_vtable: Line.VTable = .{
    .heldFn = nothingHeld,
    .canTransferFn = never,
    .readFn = refuseRead,
    .writeFn = refuseWrite,
    .goIdleFn = ignore,
    .powerUpFn = ignore,
    .publishCidFn = refuse,
    .takeAddressFn = refuse,
    .selectFn = ignoreSelect,
    .csdFn = noCsd,
};

fn nothingHeld(_: *const anyopaque) u32 {
    return 0;
}

fn never(_: *const anyopaque) bool {
    return false;
}

fn refuseRead(_: *anyopaque, _: u32, out: *Block) bool {
    @memset(out, 0);
    return false;
}

fn refuseWrite(_: *anyopaque, _: u32, _: *const Block) bool {
    return false;
}

fn ignore(_: *anyopaque) void {}

fn refuse(_: *anyopaque) bool {
    return false;
}

fn ignoreSelect(_: *anyopaque, _: u16) void {}

fn noCsd(_: *const anyopaque) [4]u32 {
    return @splat(0);
}
