//! The NOR part's two faces toward the chip: the command engine's contract
//! (periph/xspi/nor.zig) and the store's mapped window
//! (core/cpu/memory/mapped.zig).
const xspi_nor = @import("ra8_chip").periph.xspi_nor;
const mapped = @import("ra8_chip").core.cpu.mapped;
const Flash = @import("flash.zig").Flash;
const part = @import("flash.zig").part;

pub fn nor(flash: *Flash) xspi_nor.Nor {
    return .{ .context = flash, .vtable = &nor_vtable, .page_len = part.page_len };
}

pub fn window(flash: *Flash) mapped.Mapped {
    return .{ .context = flash, .vtable = &window_vtable };
}

const nor_vtable: xspi_nor.Nor.VTable = .{
    .capacityFn = capacity,
    .jedecWordFn = jedecWord,
    .byteFn = byte,
    .programFn = program,
    .eraseFn = erase,
};

const window_vtable: mapped.Mapped.VTable = .{
    .resizeFn = resize,
    .readFn = read,
    .writeFn = write,
};

fn of(context: *anyopaque) *Flash {
    return @ptrCast(@alignCast(context));
}

fn ofConst(context: *const anyopaque) *const Flash {
    return @ptrCast(@alignCast(context));
}

fn capacity(context: *const anyopaque) u32 {
    return ofConst(context).capacity;
}

fn jedecWord(context: *const anyopaque) u24 {
    return ofConst(context).jedecWord();
}

fn byte(context: *const anyopaque, address: u32) u8 {
    return ofConst(context).byte(address);
}

fn program(context: *anyopaque, address: u32, value: u8) bool {
    of(context).program(address, value) catch return false;
    return true;
}

fn erase(context: *anyopaque, address: u32) void {
    of(context).erase(address);
}

fn resize(context: *anyopaque, size: u32) mapped.Error!void {
    of(context).resize(size) catch return error.OutOfMemory;
}

fn read(context: *const anyopaque, address: u32, into: []u8) bool {
    return ofConst(context).readMapped(address, into);
}

fn write(context: *anyopaque, address: u32, bytes: []const u8) mapped.Error!bool {
    return of(context).writeMapped(address, bytes) catch error.OutOfMemory;
}
