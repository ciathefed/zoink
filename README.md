# zoink

a small http server library for zig 0.16, built on `std.http.Server` and the new `std.Io` interface.

- http/1.1 request parsing via the standard library — zoink only adds routing, middleware, and response helpers on top
- backend-agnostic concurrency: pass any `std.Io` implementation, e.g. `std.Io.Uring` on linux for a single-threaded event loop, or `std.Io.Threaded` for a portable thread-pool fallback
- path params (`:id`) and wildcards (`*path`)
- middleware chaining via `ctx.next()`
- json request/response helpers
- static file serving with path traversal protection

## requirements

zig 0.16.0.

## install

add zoink as a dependency:

```bash
zig fetch --save git+https://github.com/<you>/zoink
```

then in `build.zig`:

```zig
const zoink = b.dependency("zoink", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zoink", zoink.module("zoink"));
```

## quick start

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

see [`examples/basic.zig`](examples/basic.zig) for a fuller example covering middleware, json, app state, and static files. run it with:

```bash
zig build run
```

## routing

```zig
try router.get("/users/:id", handler);
try router.post("/users", handler);
try router.put("/users/:id", handler);
try router.patch("/users/:id", handler);
try router.delete("/users/:id", handler);
try router.any("/webhook", handler); // matches any method
```

path segments starting with `:` capture a single param; a segment starting with `*` must be last and captures the rest of the path (including slashes):

```zig
try router.get("/assets/*path", handler);
// GET /assets/css/app.css -> ctx.param("path") == "css/app.css"
```

## middleware

register with `router.use`; call `ctx.next()` to continue the chain, or return without calling it to short-circuit:

```zig
fn logger(ctx: *zoink.Context) !void {
    std.log.info("{t} {s}", .{ ctx.method, ctx.path });
    try ctx.next();
}

try router.use(logger);
```

middleware runs for every request, including ones that don't match a route (so a logger still sees 404s).

## context

`*zoink.Context` is passed to every handler and carries the request and response helpers:

- `ctx.param(name)`, `ctx.query(name)`, `ctx.header(name)`
- `ctx.text(status, body)`, `ctx.html(status, body)`, `ctx.sendJson(status, value)`, `ctx.noContent()`, `ctx.redirect(location, permanent)`
- `ctx.readJson(T)`, `ctx.readBody()`
- `ctx.state(T)` to retrieve the app state pointer set via `Server.Options.app_state`
- `ctx.allocator` — an arena scoped to the request; anything allocated through it is freed automatically

## static files

not registered directly as a route handler — call it from your own handler so the root directory can be anything you want, including a runtime value:

```zig
fn assets(ctx: *zoink.Context) !void {
    try zoink.static.serve(ctx, "public", ctx.param("path").?);
}

try router.get("/assets/*path", assets);
```

rejects any path containing a `..` segment.

## testing

```bash
zig build test
```
