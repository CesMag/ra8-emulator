//! The ThreadX symbols a `--run-for` soak finds threads through
//! (RA8EMU-619): src/board/run/soak_threads.zig walks them. An image
//! without ThreadX names neither, and its soak watches no canaries.
const elf = @import("ra8_board").image.elf;
const symbols = @import("symbols.zig");
const soak_threads = @import("ra8_board").run.soak_threads;

pub fn resolve(image: elf.Image, threads: *soak_threads.Threads) void {
    threads.head = symbols.addressOf(image, soak_threads.created_ptr_symbol);
    threads.count_at = symbols.addressOf(image, soak_threads.created_count_symbol);
}
