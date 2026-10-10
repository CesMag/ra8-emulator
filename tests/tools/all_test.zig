//! Every test under tests/tools, one per tool in tools/.
test {
    _ = @import("gate_test.zig");
    _ = @import("terms_test.zig");
    _ = @import("example_probes_test.zig");
    _ = @import("example_table_test.zig");
    _ = @import("example_budgets_test.zig");
    _ = @import("example_options_test.zig");
    _ = @import("example_expect_test.zig");
}
