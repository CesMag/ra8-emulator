//! The SD-bus card as SDHI0's slot sees it: bus_card.Card behind the line
//! the controller declares (periph/sdhi/line.zig).
const sd_line = @import("ra8_chip").periph.sdhi.line;
const Card = @import("card.zig").Card;

pub fn line(card: *Card) sd_line.Line {
    return .{ .context = card, .vtable = &vtable };
}

const vtable: sd_line.Line.VTable = .{
    .heldFn = held,
    .canTransferFn = canTransfer,
    .readFn = read,
    .writeFn = write,
    .goIdleFn = goIdle,
    .powerUpFn = powerUp,
    .publishCidFn = publishCid,
    .takeAddressFn = takeAddress,
    .selectFn = select,
    .csdFn = csd,
};

fn of(context: *anyopaque) *Card {
    return @ptrCast(@alignCast(context));
}

fn ofConst(context: *const anyopaque) *const Card {
    return @ptrCast(@alignCast(context));
}

fn held(context: *const anyopaque) u32 {
    return ofConst(context).held();
}

fn canTransfer(context: *const anyopaque) bool {
    return ofConst(context).canTransfer();
}

fn read(context: *anyopaque, lba: u32, out: *sd_line.Block) bool {
    return of(context).read(lba, out);
}

fn write(context: *anyopaque, lba: u32, data: *const sd_line.Block) bool {
    return of(context).write(lba, data);
}

fn goIdle(context: *anyopaque) void {
    of(context).goIdle();
}

fn powerUp(context: *anyopaque) void {
    of(context).powerUp();
}

fn publishCid(context: *anyopaque) bool {
    return of(context).publishCid();
}

fn takeAddress(context: *anyopaque) bool {
    return of(context).takeAddress();
}

fn select(context: *anyopaque, rca: u16) void {
    of(context).select(rca);
}

fn csd(context: *const anyopaque) [4]u32 {
    return ofConst(context).csd();
}
