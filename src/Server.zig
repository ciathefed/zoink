//! HTTP/1.1 server built on `std.http.Server`, running over any `std.Io`
//! implementation. Pass `Io.Uring` (Linux) for a single-threaded event loop,
//! or `Io.Threaded` for a portable thread-pool-backed fallback.
const std = @import("std");
const http = std.http;
const net = std.Io.net;
const router_mod = @import("router.zig");
const Router = router_mod.Router;
const Handler = router_mod.Handler;
const Context = @import("Context.zig");

const Server = @This();

allocator: std.mem.Allocator,
io: std.Io,
router: *const Router,
options: Options,
tcp_server: net.Server = undefined,
group: std.Io.Group = .init,

pub const Options = struct {
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 8192,
    max_body_bytes: usize = 1024 * 1024,
    /// Opaque pointer made available to handlers via `Context.state`.
    app_state: ?*anyopaque = null,
    /// How long a keep-alive connection may sit idle waiting for the next
    /// request to start. `null` disables it.
    idle_timeout: ?std.Io.Duration = .fromSeconds(60),
    /// How long a single request may take from the moment its headers are
    /// received through the response being fully written. `null` disables
    /// it.
    ///
    /// This only bounds time spent blocked reading from or writing to the
    /// client socket (a slow request body upload, or a client too slow to
    /// drain the response) — the two scenarios that can otherwise pin a
    /// connection open indefinitely. It does *not* bound a handler blocked
    /// on anything else: a sleep, a slow downstream call, a lock, or plain
    /// CPU-bound work. Zig 0.16's `Io.Future` has no safe way for one task
    /// to cancel work a *different* task is concurrently awaiting, which
    /// rules out a general "kill the handler after N seconds" watchdog; if
    /// you need that, bound the specific slow operation yourself (e.g. race
    /// your downstream call against `std.Io.sleep` inside the handler).
    request_timeout: ?std.Io.Duration = .fromSeconds(30),
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, router: *const Router, options: Options) Server {
    return .{
        .allocator = allocator,
        .io = io,
        .router = router,
        .options = options,
    };
}

/// Binds and starts listening. Call `run` afterward to accept connections.
pub fn listen(self: *Server, address: std.Io.net.IpAddress) !void {
    self.tcp_server = try address.listen(self.io, .{ .reuse_address = true });
}

pub fn deinit(self: *Server) void {
    self.group.cancel(self.io);
    self.group.await(self.io) catch {};
    self.tcp_server.deinit(self.io);
}

/// Accepts connections forever, handling each one concurrently. Returns only
/// on an unrecoverable accept error or when canceled.
pub fn run(self: *Server) !void {
    while (true) {
        const stream = self.tcp_server.accept(self.io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                std.log.err("zoink: accept failed: {t}", .{err});
                continue;
            },
        };
        self.group.async(self.io, handleConnection, .{ self, stream });
    }
}

fn handleConnection(self: *Server, stream: net.Stream) void {
    defer stream.close(self.io);

    const read_buf = self.allocator.alloc(u8, self.options.read_buffer_size) catch return;
    defer self.allocator.free(read_buf);
    const write_buf = self.allocator.alloc(u8, self.options.write_buffer_size) catch return;
    defer self.allocator.free(write_buf);

    var stream_reader = net.Stream.Reader.init(stream, self.io, read_buf);
    var stream_writer = net.Stream.Writer.init(stream, self.io, write_buf);

    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);

        var idle_timed_out: std.atomic.Value(bool) = .init(false);
        var idle_watch: ?std.Io.Future(void) = if (self.options.idle_timeout) |d|
            std.Io.async(self.io, idleWatchdog, .{ self.io, stream, d, &idle_timed_out })
        else
            null;

        var request = http_server.receiveHead() catch |err| {
            cancelWatchdog(self.io, &idle_watch);
            // Nothing has been written yet, so a best-effort response is
            // always safe to attempt here.
            if (idle_timed_out.load(.acquire)) writeTimeoutResponse(&stream_writer.interface) catch {};
            switch (err) {
                error.HttpConnectionClosing => return,
                else => return,
            }
        };
        cancelWatchdog(self.io, &idle_watch);

        const keep_alive = self.handleRequest(arena.allocator(), &request, stream) catch |err| keep_alive: {
            std.log.err("zoink: handler error: {t}", .{err});
            break :keep_alive false;
        };
        if (!keep_alive) return;
    }
}

fn handleRequest(self: *Server, allocator: std.mem.Allocator, request: *http.Server.Request, stream: net.Stream) !bool {
    const raw_target = request.head.target;
    const q_index = std.mem.indexOfScalar(u8, raw_target, '?');
    const path_part = if (q_index) |i| raw_target[0..i] else raw_target;
    const query_part = if (q_index) |i| raw_target[i + 1 ..] else "";

    var ctx: Context = .{
        .allocator = allocator,
        .io = self.io,
        .request = request,
        .method = request.head.method,
        .path = try allocator.dupe(u8, path_part),
        .query_string = try allocator.dupe(u8, query_part),
        .app_state = self.options.app_state,
        .max_body_bytes = self.options.max_body_bytes,
    };

    var timed_out: std.atomic.Value(bool) = .init(false);
    var watch: ?std.Io.Future(void) = if (self.options.request_timeout) |d|
        std.Io.async(self.io, activeWatchdog, .{ self.io, stream, d, &ctx.responded, &timed_out })
    else
        null;
    defer cancelWatchdog(self.io, &watch);

    const final_handler: Handler = switch (self.router.match(ctx.method, ctx.path, &ctx.params, &ctx.allowed_methods)) {
        .found => |h| h,
        .method_not_allowed => methodNotAllowed,
        .not_found => notFound,
    };

    var chain = try allocator.alloc(Handler, self.router.middlewares.items.len + 1);
    @memcpy(chain[0..self.router.middlewares.items.len], self.router.middlewares.items);
    chain[self.router.middlewares.items.len] = final_handler;
    ctx.chain = chain;

    ctx.next() catch |err| {
        if (!ctx.responded.load(.acquire)) {
            if (timed_out.load(.acquire)) {
                ctx.text(.request_timeout, "408 Request Timeout") catch {};
            } else {
                ctx.text(.internal_server_error, "500 Internal Server Error") catch {};
            }
        }
        std.log.err("zoink: handler returned error: {t}", .{err});
    };

    return request.head.keep_alive;
}

fn cancelWatchdog(io: std.Io, watch: *?std.Io.Future(void)) void {
    if (watch.*) |*w| _ = w.cancel(io);
}

/// Sleeps for `duration`, then fires if not canceled first (the caller
/// cancels it once the phase it's guarding finishes on its own, at which
/// point `Io.sleep` returns promptly instead of running the full duration).
/// Only the read side is closed, since nothing has been written yet during
/// the idle wait for a request's headers, so a best-effort timeout response
/// can still follow.
fn idleWatchdog(io: std.Io, stream: net.Stream, duration: std.Io.Duration, timed_out: *std.atomic.Value(bool)) void {
    std.Io.sleep(io, duration, .awake) catch return;
    timed_out.store(true, .release);
    stream.shutdown(io, .recv) catch {};
}

/// Same as `idleWatchdog`, but for bounding an in-flight request. If no
/// response has started yet, only the read side is closed so a best-effort
/// timeout response can still be written; otherwise both directions are
/// closed since anything further written would corrupt an in-progress
/// response.
fn activeWatchdog(io: std.Io, stream: net.Stream, duration: std.Io.Duration, responded: *std.atomic.Value(bool), timed_out: *std.atomic.Value(bool)) void {
    std.Io.sleep(io, duration, .awake) catch return;
    timed_out.store(true, .release);
    const how: net.ShutdownHow = if (responded.load(.acquire)) .both else .recv;
    stream.shutdown(io, how) catch {};
}

fn writeTimeoutResponse(writer: *std.Io.Writer) !void {
    try writer.writeAll("HTTP/1.1 408 Request Timeout\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
    try writer.flush();
}

fn notFound(ctx: *Context) !void {
    try ctx.text(.not_found, "404 Not Found");
}

fn methodNotAllowed(ctx: *Context) !void {
    var allow: std.Io.Writer.Allocating = .init(ctx.allocator);
    for (ctx.allowed_methods.slice(), 0..) |m, i| {
        if (i != 0) try allow.writer.writeAll(", ");
        try allow.writer.writeAll(@tagName(m));
    }

    try ctx.respond(.method_not_allowed, "text/plain; charset=utf-8", "405 Method Not Allowed", .{
        .extra_headers = &.{.{ .name = "allow", .value = allow.written() }},
    });
}
