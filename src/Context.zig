//! Per-request state passed to handlers and middleware.
const std = @import("std");
const http = std.http;
const router = @import("router.zig");

const Context = @This();

/// Arena allocator scoped to this single request. Freed automatically when
/// the request finishes; handlers do not need to free anything allocated
/// through it.
allocator: std.mem.Allocator,
io: std.Io,
request: *http.Server.Request,

method: http.Method,
/// Request path, percent-encoded, without the query string. Always starts with `/`.
path: []const u8,
/// Everything after `?` in the request target, or an empty string.
query_string: []const u8,
params: router.Params = .{},
/// Filled by the server when the request's path matched a route but its
/// method didn't; empty otherwise.
allowed_methods: router.AllowedMethods = .{},

/// Opaque pointer to application state set on the `Server`, if any. Use
/// `state` to retrieve it as a concrete type.
app_state: ?*anyopaque = null,

max_body_bytes: usize = 1024 * 1024,

chain: []const router.Handler = &.{},
chain_pos: usize = 0,
/// Whether a response has been sent yet. Atomic because the server's
/// per-request watchdog reads it from a separate task to decide whether a
/// timeout can still be answered with a response or must hard-close instead.
responded: std.atomic.Value(bool) = .init(false),

/// Calls the next middleware or handler in the chain. Middleware must call
/// this to continue processing; omitting the call short-circuits the chain
/// (useful for e.g. auth middleware rejecting a request).
pub fn next(ctx: *Context) anyerror!void {
    if (ctx.chain_pos >= ctx.chain.len) return;
    const handler = ctx.chain[ctx.chain_pos];
    ctx.chain_pos += 1;
    try handler(ctx);
}

/// Retrieves the application state set via `Server.Options.app_state`, cast
/// to `*T`. Asserts that state was actually set.
pub fn state(ctx: *Context, comptime T: type) *T {
    return @ptrCast(@alignCast(ctx.app_state.?));
}

pub fn param(ctx: *const Context, name: []const u8) ?[]const u8 {
    return ctx.params.get(name);
}

/// Looks up a key in the raw (not percent-decoded) query string.
pub fn query(ctx: *const Context, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, ctx.query_string, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn header(ctx: *const Context, name: []const u8) ?[]const u8 {
    var it = ctx.request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Percent-decodes `raw` into memory owned by the request arena.
pub fn percentDecodeAlloc(ctx: *Context, raw: []const u8) ![]u8 {
    const buf = try ctx.allocator.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}

/// Reads and JSON-decodes the request body as `T`. Memory referenced by the
/// returned value is owned by the request arena.
pub fn readJson(ctx: *Context, comptime T: type) !T {
    const body = try ctx.readBody();
    return std.json.parseFromSliceLeaky(T, ctx.allocator, body, .{});
}

pub const ReadBodyError = error{
    /// The connection was closed (by the client, or by the server's own
    /// timeout) before as many bytes as `content-length` promised arrived.
    BodyTruncated,
} || anyerror;

/// Reads the entire request body into memory owned by the request arena,
/// capped at `max_body_bytes`.
pub fn readBody(ctx: *Context) ReadBodyError![]u8 {
    const expected = ctx.request.head.content_length;
    const scratch = try ctx.allocator.alloc(u8, 4096);
    const body_reader = try ctx.request.readerExpectContinue(scratch);
    const body = try body_reader.allocRemaining(ctx.allocator, .limited64(ctx.max_body_bytes));
    if (expected) |len| {
        if (body.len < len) return error.BodyTruncated;
    }
    return body;
}

pub const RespondOptions = struct {
    extra_headers: []const http.Header = &.{},
    keep_alive: ?bool = null,
};

/// Sends a full response with an explicit content type.
pub fn respond(ctx: *Context, status: http.Status, content_type: []const u8, body: []const u8, options: RespondOptions) !void {
    var headers_buf: [8]http.Header = undefined;
    var n: usize = 0;
    headers_buf[n] = .{ .name = "content-type", .value = content_type };
    n += 1;
    for (options.extra_headers) |h| {
        if (n >= headers_buf.len) break;
        headers_buf[n] = h;
        n += 1;
    }

    primeBodyFraming(ctx.request);
    ctx.responded.store(true, .release);
    try ctx.request.respond(body, .{
        .status = status,
        .keep_alive = options.keep_alive orelse ctx.request.head.keep_alive,
        .extra_headers = headers_buf[0..n],
    });
}

/// A request whose method allows a body but which declares neither
/// `content-length` nor `transfer-encoding` (a body-less POST/PUT/PATCH,
/// which is valid HTTP) crashes `std.http.Server.Request.respond`'s internal
/// keep-alive body discarding, which asserts one of those is set. Settle the
/// body framing ourselves first so that assert never sees the ambiguous
/// state. A no-op once the body has already been read by the handler.
fn primeBodyFraming(request: *http.Server.Request) void {
    if (request.server.reader.state != .received_head) return;
    if (!request.head.method.requestHasBody()) return;
    if (request.head.transfer_encoding != .none or request.head.content_length != null) return;
    _ = request.readerExpectContinue(&.{}) catch {};
}

pub fn text(ctx: *Context, status: http.Status, body: []const u8) !void {
    try ctx.respond(status, "text/plain; charset=utf-8", body, .{});
}

pub fn html(ctx: *Context, status: http.Status, body: []const u8) !void {
    try ctx.respond(status, "text/html; charset=utf-8", body, .{});
}

pub fn sendJson(ctx: *Context, status: http.Status, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(ctx.allocator, value, .{});
    try ctx.respond(status, "application/json", bytes, .{});
}

pub fn noContent(ctx: *Context) !void {
    primeBodyFraming(ctx.request);
    ctx.responded.store(true, .release);
    try ctx.request.respond("", .{
        .status = .no_content,
        .keep_alive = ctx.request.head.keep_alive,
    });
}

pub fn redirect(ctx: *Context, location: []const u8, permanent: bool) !void {
    primeBodyFraming(ctx.request);
    ctx.responded.store(true, .release);
    try ctx.request.respond("", .{
        .status = if (permanent) .moved_permanently else .found,
        .keep_alive = ctx.request.head.keep_alive,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}
