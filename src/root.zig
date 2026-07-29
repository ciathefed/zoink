//! zoink: a small http server library for zig, built on `std.http.Server`
//! and `std.Io`.
const router = @import("router.zig");

pub const Server = @import("Server.zig");
pub const Context = @import("Context.zig");
pub const Router = router.Router;
pub const Handler = router.Handler;
pub const Params = router.Params;
pub const static = @import("static.zig");

test {
    _ = @import("router.zig");
}
