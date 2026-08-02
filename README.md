# zoink

A small HTTP server library for Zig 0.16, built on `std.http.Server` and the new `std.Io` interface.

- HTTP/1.1 request parsing via the standard library — zoink only adds routing, middleware, and response helpers on top
- Backend-agnostic concurrency: pass any `std.Io` implementation, e.g. `std.Io.Uring` on Linux for a single-threaded event loop, or `std.Io.Threaded` for a portable thread-pool fallback
- Path params (`:id`) and wildcards (`*path`)
- Middleware chaining via `ctx.next()`
- JSON request/response helpers
- Static file serving with path traversal protection

## Requirements

Zig 0.16.0.

## Install

Add zoink as a dependency:

```bash
zig fetch --save git+https://github.com/<you>/zoink
```

Then in `build.zig`:

```zig
const zoink = b.dependency("zoink", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zoink", zoink.module("zoink"));
```

## Quick start

```zig
const std = @import("std");
const zoink = @import("zoink");

fn index(ctx: *zoink.Context) !void {
    try ctx.text(.ok, "welcome to zoink");
}

fn greet(ctx: *zoink.Context) !void {
    const name = ctx.param("name").?;
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "hello, {s}!", .{name});
    try ctx.text(.ok, body);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var router: zoink.Router = .init(allocator);
    defer router.deinit();

    try router.get("/", index);
    try router.get("/greet/:name", greet);

    var server: zoink.Server = .init(allocator, io, &router, .{});
    defer server.deinit();

    try server.listen(.{ .ip4 = .loopback(8080) });
    try server.run();
}
```

See [`examples/basic.zig`](examples/basic.zig) for a fuller example covering middleware, JSON, app state, and static files. Run it with:

```bash
zig build run
```

## Routing

```zig
try router.get("/users/:id", handler);
try router.post("/users", handler);
try router.put("/users/:id", handler);
try router.patch("/users/:id", handler);
try router.delete("/users/:id", handler);
try router.any("/webhook", handler); // matches any method
```

Path segments starting with `:` capture a single param; a segment starting with `*` must be last and captures the rest of the path (including slashes):

```zig
try router.get("/assets/*path", handler);
// GET /assets/css/app.css -> ctx.param("path") == "css/app.css"
```

Requests to a path that matches a route but with the wrong method get a `405` with an `Allow` header instead of a `404`.

## Middleware

Register with `router.use`; call `ctx.next()` to continue the chain, or return without calling it to short-circuit:

```zig
fn logger(ctx: *zoink.Context) !void {
    std.log.info("{t} {s}", .{ ctx.method, ctx.path });
    try ctx.next();
}

try router.use(logger);
```

Middleware runs for every request, including ones that don't match a route (so a logger still sees 404s).

## Context

`*zoink.Context` is passed to every handler and carries the request and response helpers:

- `ctx.param(name)`, `ctx.query(name)`, `ctx.header(name)`, `ctx.cookie(name)`
- `ctx.text(status, body)`, `ctx.html(status, body)`, `ctx.sendJson(status, value)`, `ctx.noContent()`, `ctx.redirect(location, permanent)`
- `ctx.setCookie(name, value, options)` — `HttpOnly` and `SameSite=Lax` by default
- `ctx.readJson(T)`, `ctx.readBody()`
- `ctx.state(T)` to retrieve the app state pointer set via `Server.Options.app_state`
- `ctx.allocator` — an arena scoped to the request; anything allocated through it is freed automatically

## Timeouts

`Server.Options` has `idle_timeout` (default 60s) and `request_timeout` (default 30s), both configurable or `null` to disable. They bound time spent blocked on the client socket — a slow request body upload, or a client too slow to read the response — and respond `408` where possible. They do not bound a handler blocked on something other than the client connection (a sleep, a slow downstream call, a lock, or CPU-bound work); see the doc comment on `request_timeout` for why.

## Static files

Not registered directly as a route handler — call it from your own handler so the root directory can be anything you want, including a runtime value:

```zig
fn assets(ctx: *zoink.Context) !void {
    try zoink.static.serve(ctx, "public", ctx.param("path").?);
}

try router.get("/assets/*path", assets);
```

Rejects any path containing a `..` segment.

## Testing

```bash
zig build test
```
