//! The NOR part on the far side of XSPI0's manual-command engine. The chip
//! owns this contract: the part (src/components/nor_flash) implements it and
//! the board plugs it in, so this block never imports a part.
pub const Nor = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// The part's page: a program's address counter wraps inside it.
    page_len: u32,

    pub const VTable = struct {
        capacityFn: *const fn (*const anyopaque) u32,
        jedecWordFn: *const fn (*const anyopaque) u24,
        byteFn: *const fn (*const anyopaque, u32) u8,
        /// False when the part could not find room to hold the program.
        programFn: *const fn (*anyopaque, u32, u8) bool,
        eraseFn: *const fn (*anyopaque, u32) void,
    };

    pub fn capacity(self: Nor) u32 {
        return self.vtable.capacityFn(self.context);
    }

    pub fn jedecWord(self: Nor) u24 {
        return self.vtable.jedecWordFn(self.context);
    }

    pub fn byte(self: Nor, address: u32) u8 {
        return self.vtable.byteFn(self.context, address);
    }

    pub fn program(self: Nor, address: u32, value: u8) bool {
        return self.vtable.programFn(self.context, address, value);
    }

    /// Erase the sector the address falls in.
    pub fn erase(self: Nor, address: u32) void {
        self.vtable.eraseFn(self.context, address);
    }

    /// Whether `len` bytes from `address` are all on the part.
    pub fn holds(self: Nor, address: u32, len: u32) bool {
        return @as(u64, address) + len <= self.capacity();
    }

    /// Where the index-th byte of a program starting at `address` lands.
    pub fn programStep(self: Nor, address: u32, index: u32) u32 {
        const page = address & ~(self.page_len - 1);
        return page + ((address +% index) % self.page_len);
    }

    pub fn crossesPage(self: Nor, address: u32, len: u32) bool {
        if (len == 0) return false;
        return (address % self.page_len) + len > self.page_len;
    }
};
