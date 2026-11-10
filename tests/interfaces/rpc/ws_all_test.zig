//! Bundle runner for WebSocket RPC transport tests (RA8EMU-1241).
//! Bundles handshake, frame codec, and transport adapter into a single
//! import to preserve line headroom in tests/all_host.zig (< 400 lines).
const std = @import("std");

test {
    _ = @import("ws_handshake_test.zig");
    _ = @import("ws_frame_test.zig");
    _ = @import("ws_transport_test.zig");
    _ = @import("ws_stress_test.zig");
    _ = @import("session/metrics_stress_test.zig");
    _ = @import("session/metrics_rapid_test.zig");
}
